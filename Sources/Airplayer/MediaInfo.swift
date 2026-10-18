import Foundation

struct VideoTrack {
    let index: Int
    let codec: String
    let width: Int
    let height: Int
    let frameRate: Double
    let transfer: String?
    let bitRate: Int?
    let dvProfile: Int?
    let dvLevel: Int?
    let dvCompatibility: Int?
    let startTime: Double

    /// Video that can be stream-copied into fMP4 for AirPlay; everything else is re-encoded.
    var canCopy: Bool { codec == "hevc" || codec == "h264" }

    var range: String {
        if dvProfile == 5 { return "PQ" }
        switch transfer {
        case "smpte2084": return "PQ"
        case "arib-std-b67": return "HLG"
        default: return "SDR"
        }
    }
}

struct AudioTrack: Identifiable {
    let index: Int
    let codec: String
    let profile: String?
    let language: String?
    let title: String?
    let channels: Int
    let sampleRate: Int
    let bitRate: Int?
    let isDefault: Bool
    /// pts of the first packet and frame duration, both in seconds (needed to cut on frame boundaries).
    var firstPTS: Double = 0
    var frameDuration: Double = 0

    var id: Int { index }
    var canCopy: Bool { ["ac3", "eac3", "aac"].contains(codec) && frameDuration > 0 }
    var isAtmos: Bool { profile?.localizedCaseInsensitiveContains("atmos") == true }
}

enum SubtitleSource {
    case embedded(streamIndex: Int)
    case external(URL)
}

struct SubtitleTrack: Identifiable {
    let id: Int
    let source: SubtitleSource
    let codec: String
    let language: String?
    let title: String?
    let isForced: Bool
    let isDefault: Bool

    static let textCodecs: Set<String> = ["subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text", "microdvd", "subviewer", "jacosub", "sami", "realtext", "mpl2", "vplayer", "pjs", "stl"]
    var isText: Bool { Self.textCodecs.contains(codec) }
}

struct MediaInfo {
    let url: URL
    let duration: Double
    let bitRate: Int?
    let video: VideoTrack
    var audio: [AudioTrack]
    var subtitles: [SubtitleTrack]
    /// Segment boundaries in source seconds; segment n covers [boundaries[n], boundaries[n+1]).
    let boundaries: [Double]

    var segmentCount: Int { boundaries.count - 1 }
}

enum MediaProbe {
    static let targetSegment = 6.0

    static func probe(_ url: URL) async throws -> MediaInfo {
        let tools = try Tools.requireFFmpeg()
        let json = try await Tools.run(tools.ffprobe, ["-v", "error", "-print_format", "json",
                                                       "-show_format", "-show_streams", url.path])
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]] else {
            throw ToolError(message: "Could not read media info")
        }
        let format = root["format"] as? [String: Any] ?? [:]
        let duration = double(format["duration"]) ?? 0

        var video: VideoTrack?
        var audio: [AudioTrack] = []
        var subs: [SubtitleTrack] = []

        for s in streams {
            let type = s["codec_type"] as? String
            let index = s["index"] as? Int ?? 0
            let codec = s["codec_name"] as? String ?? "unknown"
            let tags = s["tags"] as? [String: Any] ?? [:]
            let disp = s["disposition"] as? [String: Any] ?? [:]
            let lang = (tags["language"] as? String).flatMap { $0 == "und" ? nil : $0 }
            let title = tags["title"] as? String

            switch type {
            case "video" where video == nil && (disp["attached_pic"] as? Int) != 1:
                var dv: [String: Any]?
                for sd in s["side_data_list"] as? [[String: Any]] ?? [] where sd["dv_profile"] != nil { dv = sd }
                video = VideoTrack(index: index, codec: codec,
                                   width: s["width"] as? Int ?? 0, height: s["height"] as? Int ?? 0,
                                   frameRate: rate(s["avg_frame_rate"]) ?? rate(s["r_frame_rate"]) ?? 24,
                                   transfer: s["color_transfer"] as? String,
                                   bitRate: int(s["bit_rate"]),
                                   dvProfile: dv?["dv_profile"] as? Int, dvLevel: dv?["dv_level"] as? Int,
                                   dvCompatibility: dv?["dv_bl_signal_compatibility_id"] as? Int,
                                   startTime: double(s["start_time"]) ?? 0)
            case "audio":
                audio.append(AudioTrack(index: index, codec: codec, profile: s["profile"] as? String,
                                        language: lang, title: title,
                                        channels: s["channels"] as? Int ?? 2,
                                        sampleRate: int(s["sample_rate"]) ?? 48000,
                                        bitRate: int(s["bit_rate"]),
                                        isDefault: (disp["default"] as? Int) == 1))
            case "subtitle":
                subs.append(SubtitleTrack(id: subs.count, source: .embedded(streamIndex: index), codec: codec,
                                          language: lang, title: title,
                                          isForced: (disp["forced"] as? Int) == 1,
                                          isDefault: (disp["default"] as? Int) == 1))
            default: break
            }
        }
        guard let video else { throw ToolError(message: "No video stream found") }

        let audioTracks = audio
        async let timings = audioTimings(url: url, tracks: audioTracks, ffprobe: tools.ffprobe)
        let boundaries = video.canCopy
            ? try await keyframeBoundaries(url: url, video: video, duration: duration, ffprobe: tools.ffprobe)
            : gridBoundaries(video: video, duration: duration)
        audio = await timings

        return MediaInfo(url: url, duration: duration, bitRate: int(format["bit_rate"]),
                         video: video, audio: audio, subtitles: subs, boundaries: boundaries)
    }

    /// Finds keyframes roughly every `targetSegment` seconds by seeking through the container index
    /// (fast: ~1-2 s even for a 30 GB file, since no packet data has to be read).
    static func keyframeBoundaries(url: URL, video: VideoTrack, duration: Double, ffprobe: String) async throws -> [Double] {
        let probes = stride(from: 0.0, to: duration, by: targetSegment).map { "\($0.ff)%+#1" }
        var found = try await keyframes(url: url, video: video, ffprobe: ffprobe,
                                        extra: ["-read_intervals", probes.joined(separator: ",")])
        if found.count < Int(duration / 60) {
            // Container without a usable index (e.g. some AVIs): scan every packet.
            found = try await keyframes(url: url, video: video, ffprobe: ffprobe, extra: [])
        }
        var result: [Double] = []
        for k in found.sorted() where k < duration - 0.5 {
            if let last = result.last, k - last < targetSegment * 0.5 { continue }
            result.append(k)
        }
        if result.isEmpty { result = [video.startTime] }
        result.append(duration)
        return result
    }

    private static func keyframes(url: URL, video: VideoTrack, ffprobe: String, extra: [String]) async throws -> [Double] {
        let out = try await Tools.run(ffprobe, ["-v", "error", "-select_streams", "\(video.index)",
                                                "-show_entries", "packet=pts_time,flags", "-of", "csv=p=0"]
                                      + extra + [url.path])
        return String(decoding: out, as: UTF8.self).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: ",")
            guard parts.count >= 2, parts[1].hasPrefix("K") else { return nil }
            return Double(parts[0])
        }
    }

    /// For re-encoded video we choose the keyframes, so segments sit on an exact frame grid.
    static func gridBoundaries(video: VideoTrack, duration: Double) -> [Double] {
        let frames = max(1, (targetSegment * video.frameRate).rounded())
        let step = frames / video.frameRate
        var result = Array(stride(from: video.startTime, to: duration, by: step))
        if let last = result.last, duration - last < 0.2, result.count > 1 { result.removeLast() }
        result.append(duration)
        return result
    }

    private static func audioTimings(url: URL, tracks: [AudioTrack], ffprobe: String) async -> [AudioTrack] {
        await withTaskGroup(of: (Int, Double, Double)?.self) { group in
            for (i, t) in tracks.enumerated() {
                group.addTask {
                    guard let out = try? await Tools.run(ffprobe, ["-v", "error", "-select_streams", "\(t.index)",
                                                                   "-show_entries", "packet=pts_time,duration_time",
                                                                   "-of", "csv=p=0", "-read_intervals", "%+#3", url.path])
                    else { return nil }
                    let rows = String(decoding: out, as: UTF8.self).split(separator: "\n")
                        .map { $0.split(separator: ",").compactMap { Double($0) } }
                        .filter { $0.count == 2 }
                    guard let first = rows.first else { return nil }
                    return (i, first[0], first[1])
                }
            }
            var result = tracks
            for await r in group {
                if let (i, pts, dur) = r { result[i].firstPTS = pts; result[i].frameDuration = dur }
            }
            return result
        }
    }

    static func double(_ v: Any?) -> Double? {
        if let s = v as? String { return Double(s) }
        return v as? Double
    }

    static func int(_ v: Any?) -> Int? {
        if let s = v as? String { return Int(s) }
        return v as? Int
    }

    static func rate(_ v: Any?) -> Double? {
        guard let s = v as? String else { return nil }
        let p = s.split(separator: "/").compactMap { Double($0) }
        guard p.count == 2, p[1] > 0, p[0] > 0 else { return nil }
        return p[0] / p[1]
    }
}
