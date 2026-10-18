import Foundation

/// Serves one movie as an HLS presentation: a master playlist with one video variant,
/// every audio track as an alternate audio rendition, and every text subtitle as a WebVTT rendition.
final class HLSSession: @unchecked Sendable {
    let id = UUID().uuidString.prefix(8).lowercased()
    private(set) var info: MediaInfo
    let segmenter: Segmenter
    let subtitles: SubtitleStore
    private var videoCodec: (codec: String, supplemental: String?) = ("hvc1", nil)
    private var version = 0
    private let lock = NSLock()

    init(info: MediaInfo) throws {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("Airplayer", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.info = info
        segmenter = try Segmenter(info: info, workDir: work.appendingPathComponent("seg"))
        subtitles = try SubtitleStore(info: info, workDir: work.appendingPathComponent("subs"))
    }

    /// Generates the first video segment (to learn the exact codec string) and starts subtitle extraction.
    func prepare() async throws {
        let initData = try await segmenter.videoInit()
        videoCodec = MP4.videoCodec(initSegment: initData)
        await subtitles.startExtraction()
    }

    func shutdown() async { await segmenter.shutdown() }

    @discardableResult
    func addExternalSubtitle(_ url: URL, movie: URL) async -> SubtitleTrack {
        let track: SubtitleTrack = lock.withLock {
            let t = SubtitleTrack(id: info.subtitles.count, source: .external(url),
                                  codec: url.pathExtension.lowercased(),
                                  language: SubtitleStore.guessLanguage(url, movie: movie),
                                  title: url.lastPathComponent,
                                  isForced: url.lastPathComponent.lowercased().contains("forced"), isDefault: false)
            info.subtitles.append(t)
            version += 1
            return t
        }
        await subtitles.addExternal(track)
        return track
    }

    /// Path of the master playlist; changes whenever the set of renditions changes so AVPlayer reloads it.
    var masterPath: String { "/s/\(id)/master\(lock.withLock { version }).m3u8" }

    // MARK: - Routing

    func handle(_ parts: [String]) async -> HTTPResponse {
        do {
            switch parts.count {
            case 1 where parts[0].hasPrefix("master"):
                return .text(masterPlaylist(), type: "application/vnd.apple.mpegurl")
            case 1 where parts[0] == "v.m3u8":
                return .text(mediaPlaylist(durations: videoDurations(), dir: "v", ext: "m4s"), type: "application/vnd.apple.mpegurl")
            case 1 where parts[0].hasPrefix("a") && parts[0].hasSuffix(".m3u8"):
                guard let a = Int(parts[0].dropFirst().dropLast(5)), info.audio.indices.contains(a) else { break }
                return .text(mediaPlaylist(durations: await segmenter.audioDurations(a), dir: "a\(a)", ext: "m4s"),
                             type: "application/vnd.apple.mpegurl")
            case 1 where parts[0].hasPrefix("t") && parts[0].hasSuffix(".m3u8"):
                guard let t = Int(parts[0].dropFirst().dropLast(5)) else { break }
                return .text(mediaPlaylist(durations: videoDurations(), dir: "t\(t)", ext: "vtt", withMap: false),
                             type: "application/vnd.apple.mpegurl")
            case 2:
                let dir = parts[0], file = parts[1]
                if dir == "v" {
                    if file == "init.mp4" { return HTTPResponse(contentType: "video/mp4", body: try await segmenter.videoInit()) }
                    if let n = segmentNumber(file, "m4s") {
                        return HTTPResponse(contentType: "video/iso.segment", body: try await segmenter.videoSegment(n))
                    }
                } else if dir.hasPrefix("a"), let a = Int(dir.dropFirst()), info.audio.indices.contains(a) {
                    if file == "init.mp4" { return HTTPResponse(contentType: "video/mp4", body: try await segmenter.audioInit(a)) }
                    if let n = segmentNumber(file, "m4s") {
                        return HTTPResponse(contentType: "video/iso.segment", body: try await segmenter.audioSegment(a, n))
                    }
                } else if dir.hasPrefix("t"), let t = Int(dir.dropFirst()), let n = segmentNumber(file, "vtt") {
                    let b = info.boundaries
                    let text = try await subtitles.segment(t, start: b[n], end: b[n + 1])
                    return .text(text, type: "text/vtt")
                }
            default: break
            }
            return .error(404, "not found")
        } catch {
            return .error(500, error.localizedDescription)
        }
    }

    private func segmentNumber(_ file: String, _ ext: String) -> Int? {
        guard file.hasSuffix("." + ext), let n = Int(file.dropLast(ext.count + 1)), n >= 0, n < info.segmentCount
        else { return nil }
        return n
    }

    // MARK: - Playlists

    private func videoDurations() -> [Double] {
        let b = info.boundaries
        return (0..<info.segmentCount).map { b[$0 + 1] - b[$0] }
    }

    private func mediaPlaylist(durations: [Double], dir: String, ext: String, withMap: Bool = true) -> String {
        let target = Int((durations.max() ?? 6).rounded())
        var s = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(max(1, target))\n"
        s += "#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n"
        if withMap { s += "#EXT-X-MAP:URI=\"\(dir)/init.mp4\"\n" }
        for (i, d) in durations.enumerated() {
            s += String(format: "#EXTINF:%.6f,\n", d) + "\(dir)/\(i).\(ext)\n"
        }
        return s + "#EXT-X-ENDLIST\n"
    }

    private func masterPlaylist() -> String {
        let info = lock.withLock { self.info }
        var s = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n\n"

        let defaultAudio = info.audio.firstIndex { $0.isDefault } ?? 0
        var audioCodecs: [String] = []
        var maxAudioRate = 0
        var usedNames = Set<String>()
        for (i, a) in info.audio.enumerated() {
            let codec = Self.audioCodec(a)
            if !audioCodecs.contains(codec) { audioCodecs.append(codec) }
            maxAudioRate = max(maxAudioRate, a.bitRate ?? 640_000)
            let name = Self.unique(Self.audioName(a, number: i + 1), &usedNames)
            let channels = a.isAtmos && a.canCopy ? "16/JOC" : "\(a.canCopy ? a.channels : min(a.channels, 6))"
            s += "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"\(name)\""
            if let lang = Self.bcp47(a.language) { s += ",LANGUAGE=\"\(lang)\"" }
            s += ",DEFAULT=\(i == defaultAudio ? "YES" : "NO"),AUTOSELECT=YES,CHANNELS=\"\(channels)\",URI=\"a\(i).m3u8\"\n"
        }

        let textSubs = info.subtitles.filter { $0.isText }
        if !textSubs.isEmpty { s += "\n" }
        usedNames.removeAll()
        for t in textSubs {
            let name = Self.unique(Self.subtitleName(t), &usedNames)
            s += "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"\(name)\""
            if let lang = Self.bcp47(t.language) { s += ",LANGUAGE=\"\(lang)\"" }
            s += ",DEFAULT=NO,AUTOSELECT=\(t.isForced ? "YES" : "NO"),FORCED=\(t.isForced ? "YES" : "NO"),URI=\"t\(t.id).m3u8\"\n"
        }

        let v = info.video
        let videoRate = v.bitRate ?? info.bitRate ?? 20_000_000
        let peak = Int(Double(videoRate) * 1.6) + maxAudioRate
        let codecs = ([videoCodec.codec] + audioCodecs).joined(separator: ",")
        s += "\n#EXT-X-STREAM-INF:BANDWIDTH=\(peak),AVERAGE-BANDWIDTH=\(videoRate + maxAudioRate),CODECS=\"\(codecs)\""
        if let sup = videoCodec.supplemental { s += ",SUPPLEMENTAL-CODECS=\"\(sup)\"" }
        s += ",RESOLUTION=\(v.width)x\(v.height),FRAME-RATE=\(String(format: "%.3f", v.frameRate))"
        s += ",VIDEO-RANGE=\(v.canCopy ? v.range : "SDR")"
        if !info.audio.isEmpty { s += ",AUDIO=\"aud\"" }
        if !textSubs.isEmpty { s += ",SUBTITLES=\"subs\"" }
        s += "\nv.m3u8\n"
        return s
    }

    // MARK: - Naming

    static func audioCodec(_ a: AudioTrack) -> String {
        guard a.canCopy else { return AudioJob.codec(for: a) }
        switch a.codec {
        case "ac3": return "ac-3"
        case "eac3": return "ec-3"
        default: return a.profile?.contains("HE") == true ? "mp4a.40.5" : "mp4a.40.2"
        }
    }

    static func languageName(_ code: String?) -> String? {
        guard let code else { return nil }
        let id = bcp47(code) ?? code
        return Locale.current.localizedString(forLanguageCode: id)?.capitalized
    }

    static func bcp47(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        let lc = Locale.LanguageCode(code)
        return lc.identifier(.alpha2) ?? lc.identifier
    }

    static func audioName(_ a: AudioTrack, number: Int) -> String {
        let codec = ["ac3": "AC-3", "eac3": "E-AC-3", "aac": "AAC", "dts": "DTS", "truehd": "TrueHD",
                     "flac": "FLAC", "mp3": "MP3", "opus": "Opus", "vorbis": "Vorbis"][a.codec] ?? a.codec.uppercased()
        let layout = a.channels == 6 ? "5.1" : a.channels == 8 ? "7.1" : a.channels == 2 ? "2.0" : a.channels == 1 ? "Mono" : "\(a.channels)ch"
        var parts = ["\(number)."]
        if let lang = languageName(a.language) { parts.append(lang) }
        if let title = a.title, !title.isEmpty { parts.append("– \(title)") }
        var tech = "\(codec)\(a.isAtmos ? " Atmos" : "") \(layout)"
        if let br = a.bitRate { tech += " \(br / 1000)k" }
        if !a.canCopy { tech += " → \(AudioJob.codec(for: a) == "ec-3" ? "E-AC-3" : "AAC")" }
        parts.append("(\(tech))")
        return sanitize(parts.joined(separator: " "))
    }

    static func subtitleName(_ t: SubtitleTrack) -> String {
        var parts: [String] = []
        if let lang = languageName(t.language) { parts.append(lang) }
        if let title = t.title, !title.isEmpty { parts.append(title) }
        if case .external = t.source, t.title == nil { parts.append("external") }
        if t.isForced { parts.append("forced") }
        if parts.isEmpty { parts.append("Subtitles \(t.id + 1)") }
        return sanitize(parts.joined(separator: " – "))
    }

    private static func sanitize(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ")
    }

    private static func unique(_ name: String, _ used: inout Set<String>) -> String {
        var n = name, k = 2
        while used.contains(n) { n = "\(name) #\(k)"; k += 1 }
        used.insert(n)
        return n
    }
}

/// Routes `/s/<session>/...` requests to the right session.
final class SessionRegistry: @unchecked Sendable {
    private var sessions: [String: HLSSession] = [:]
    private let lock = NSLock()

    func add(_ s: HLSSession) { lock.withLock { sessions[String(s.id)] = s } }
    func remove(_ s: HLSSession) { _ = lock.withLock { sessions.removeValue(forKey: String(s.id)) } }

    func handle(_ req: HTTPRequest) async -> HTTPResponse {
        let parts = req.path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "s", let session = lock.withLock({ sessions[parts[1]] }) else {
            return .error(404, "not found")
        }
        return await session.handle(Array(parts.dropFirst(2)))
    }
}
