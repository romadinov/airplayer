import Foundation

struct Cue {
    let start: Double
    let end: Double
    let text: String
}

/// Converts embedded and external text subtitles to WebVTT and serves them in HLS-sized pieces.
actor SubtitleStore {
    private let info: MediaInfo
    private let ffmpeg: String
    private let workDir: URL
    private var tracks: [SubtitleTrack]
    private var cues: [Int: [Cue]] = [:]
    private var embeddedTask: Task<Void, Error>?
    private var externalTasks: [Int: Task<[Cue], Error>] = [:]

    init(info: MediaInfo, workDir: URL) throws {
        self.info = info
        self.tracks = info.subtitles
        self.ffmpeg = try Tools.requireFFmpeg().ffmpeg
        self.workDir = workDir
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    /// Starts extracting all embedded text subtitles in a single pass over the file.
    func startExtraction() {
        guard embeddedTask == nil else { return }
        let embedded = tracks.filter { if case .embedded = $0.source { return $0.isText } else { return false } }
        guard !embedded.isEmpty else { return }
        let ffmpeg = ffmpeg, url = info.url, dir = workDir
        embeddedTask = Task.detached {
            var args = ["-nostdin", "-v", "error", "-i", url.path]
            for t in embedded {
                guard case .embedded(let idx) = t.source else { continue }
                args += ["-map", "0:\(idx)", "-c:s", "webvtt", "-f", "webvtt",
                         dir.appendingPathComponent("sub\(t.id).vtt").path, "-y"]
            }
            _ = try await Tools.run(ffmpeg, args)
            var parsed: [Int: [Cue]] = [:]
            for t in embedded {
                let text = (try? String(contentsOf: dir.appendingPathComponent("sub\(t.id).vtt"), encoding: .utf8)) ?? ""
                parsed[t.id] = Self.parseVTT(text)
            }
            await self.store(parsed)
        }
    }

    private func store(_ parsed: [Int: [Cue]]) { cues.merge(parsed) { $1 } }

    func addExternal(_ track: SubtitleTrack) {
        tracks.append(track)
        guard case .external(let url) = track.source else { return }
        let ffmpeg = ffmpeg, dir = workDir, id = track.id
        externalTasks[id] = Task.detached {
            let data = try Data(contentsOf: url)
            let utf8 = dir.appendingPathComponent("ext\(id).\(url.pathExtension.lowercased())")
            try Data(Self.decodeText(data).utf8).write(to: utf8)
            let out = dir.appendingPathComponent("ext\(id).vtt")
            _ = try await Tools.run(ffmpeg, ["-nostdin", "-v", "error", "-sub_charenc", "UTF-8", "-i", utf8.path,
                                             "-c:s", "webvtt", "-f", "webvtt", out.path, "-y"])
            return Self.parseVTT(try String(contentsOf: out, encoding: .utf8))
        }
    }

    func cues(for id: Int) async throws -> [Cue] {
        if let c = cues[id] { return c }
        if let t = externalTasks[id] {
            let c = try await t.value
            cues[id] = c
            return c
        }
        startExtraction()
        try await embeddedTask?.value
        return cues[id] ?? []
    }

    /// One WebVTT segment covering [start, end). Cue times are source timestamps, which equal the
    /// fMP4 media timestamps, so the timestamp map is the identity.
    func segment(_ id: Int, start: Double, end: Double) async throws -> String {
        var out = "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n\n"
        for c in try await cues(for: id) where c.start < end && c.end > start {
            out += "\(Self.time(c.start)) --> \(Self.time(c.end))\n\(c.text)\n\n"
        }
        return out
    }

    // MARK: - Parsing

    static func parseVTT(_ text: String) -> [Cue] {
        var result: [Cue] = []
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let i = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[i].components(separatedBy: "-->")
            guard parts.count == 2,
                  let s = parseTime(parts[0]),
                  let e = parseTime(parts[1].split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? "")
            else { continue }
            let body = lines[(i + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { result.append(Cue(start: s, end: e, text: body)) }
        }
        return result.sorted { $0.start < $1.start }
    }

    static func parseTime(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for p in parts {
            guard let v = Double(p.replacingOccurrences(of: ",", with: ".")) else { return nil }
            total = total * 60 + v
        }
        return total
    }

    static func time(_ t: Double) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    /// Decodes subtitle text in UTF-8/UTF-16, or guesses a legacy code page (Cyrillic files are
    /// very often Windows-1251).
    static func decodeText(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }

        func enc(_ cf: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue)))
        }
        for e in [enc(.windowsCyrillic), enc(.KOI8_R)] {
            guard let s = String(data: data, encoding: e) else { continue }
            let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            let cyrillic = letters.filter { (0x0400...0x04FF).contains($0.value) }
            // In the wrong Cyrillic code page text decodes to mostly upper/lower-case-mixed noise;
            // require a clear majority of lowercase Cyrillic letters.
            let lower = cyrillic.filter { CharacterSet.lowercaseLetters.contains($0) }
            if letters.count > 0, Double(cyrillic.count) / Double(letters.count) > 0.5,
               Double(lower.count) / Double(max(1, cyrillic.count)) > 0.6 { return s }
        }
        var converted: NSString?
        _ = NSString.stringEncoding(for: data, encodingOptions: [:], convertedString: &converted, usedLossyConversion: nil)
        return (converted as String?) ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: - External subtitle discovery

    static let externalExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "smi", "txt"]

    /// Subtitle files next to the movie (or in a Subs/Subtitles folder) whose name starts with the movie's name.
    static func discover(for movie: URL) -> [URL] {
        let fm = FileManager.default
        let dir = movie.deletingLastPathComponent()
        let base = movie.deletingPathExtension().lastPathComponent.lowercased()
        var dirs = [dir]
        for name in ["Subs", "Subtitles", "subs", "subtitles", "Sub", "RUS Subs", "ENG Subs"] {
            dirs.append(dir.appendingPathComponent(name))
        }
        var found: [URL] = []
        for d in dirs {
            guard let items = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil) else { continue }
            for url in items where externalExtensions.contains(url.pathExtension.lowercased()) {
                let name = url.deletingPathExtension().lastPathComponent.lowercased()
                let inSubfolder = d != dir
                guard inSubfolder || name.hasPrefix(base) else { continue }
                // A .sub with a matching .idx is VobSub (bitmap), which can't become WebVTT.
                if url.pathExtension.lowercased() == "sub",
                   fm.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("idx").path) { continue }
                found.append(url)
            }
        }
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Guesses a language code from a file name like "Movie.rus.srt" or "Movie.Russian.forced.srt".
    static func guessLanguage(_ url: URL, movie: URL) -> String? {
        let base = movie.deletingPathExtension().lastPathComponent
        var name = url.deletingPathExtension().lastPathComponent
        if name.hasPrefix(base) { name = String(name.dropFirst(base.count)) }
        let tokens = name.lowercased().split(whereSeparator: { !$0.isLetter })
        let names: [String: String] = ["russian": "rus", "rus": "rus", "ru": "rus", "english": "eng", "eng": "eng",
                                        "en": "eng", "ukrainian": "ukr", "ukr": "ukr", "uk": "ukr", "ua": "ukr",
                                        "german": "ger", "ger": "ger", "deu": "ger", "de": "ger", "french": "fre",
                                        "fre": "fre", "fra": "fre", "fr": "fre", "spanish": "spa", "spa": "spa",
                                        "es": "spa", "italian": "ita", "ita": "ita", "it": "ita"]
        for t in tokens.reversed() { if let code = names[String(t)] { return code } }
        return nil
    }
}
