import Foundation

/// Produces fMP4 HLS segments on demand straight from the source file.
///
/// Stream-copyable tracks (HEVC/H.264 video, AC-3/E-AC-3/AAC audio) are cut statelessly: every
/// request runs a short ffmpeg remux of just that time range, and the resulting fragments are
/// re-timed so their decode times equal the source timestamps. Other video is re-encoded per
/// segment with VideoToolbox; other audio is transcoded by a long-running job per track.
actor Segmenter {
    let info: MediaInfo
    private let ffmpeg: String
    private let workDir: URL
    private var inits: [String: Data] = [:]
    private var cache: [String: Data] = [:]
    private var cacheOrder: [String] = []
    private var inFlight: [String: Task<Data, Error>] = [:]
    private var jobs: [Int: AudioJob] = [:]

    static let audioJobSegment = 6.144     // 192 AC-3 frames / 288 AAC frames at 48 kHz

    init(info: MediaInfo, workDir: URL) throws {
        self.info = info
        self.ffmpeg = try Tools.requireFFmpeg().ffmpeg
        self.workDir = workDir
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    deinit { for job in jobs.values { job.stop() } }

    func shutdown() {
        for job in jobs.values { job.stop() }
        jobs.removeAll()
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - Public API

    func videoInit() async throws -> Data {
        if let d = inits["v"] { return d }
        _ = try await videoSegment(0)
        guard let d = inits["v"] else { throw ToolError(message: "no video init segment") }
        return d
    }

    func videoSegment(_ n: Int) async throws -> Data {
        let data = try await cached("v/\(n)") { try await self.makeVideoSegment(n) }
        if n + 1 < info.segmentCount {
            Task { _ = try? await self.cached("v/\(n + 1)") { try await self.makeVideoSegment(n + 1) } }
        }
        return data
    }

    func audioInit(_ a: Int) async throws -> Data {
        let track = info.audio[a]
        if track.canCopy {
            if let d = inits["a\(a)"] { return d }
            _ = try await audioSegment(a, 0)
            return inits["a\(a)"] ?? Data()
        }
        return try await job(for: a, segment: 0, restartIfFar: false).initSegment()
    }

    func audioSegment(_ a: Int, _ n: Int) async throws -> Data {
        let track = info.audio[a]
        if track.canCopy {
            return try await cached("a\(a)/\(n)") { try await self.makeCopiedAudioSegment(a, n) }
        }
        let job = try await job(for: a, segment: n, restartIfFar: true)
        return try await job.segment(n)
    }

    /// Segment layout of an audio rendition: durations per segment.
    func audioDurations(_ a: Int) -> [Double] {
        let track = info.audio[a]
        if track.canCopy {
            let b = info.boundaries
            return (0..<info.segmentCount).map { n in
                Double(frameIndex(track, b[n + 1], last: n + 1 == info.segmentCount) - frameIndex(track, b[n], last: false))
                    * track.frameDuration
            }
        }
        let len = Self.audioJobSegment
        let count = Int((info.duration / len).rounded(.up))
        return (0..<count).map { $0 == count - 1 ? info.duration - Double(count - 1) * len : len }
    }

    // MARK: - Caching

    private func cached(_ key: String, _ make: @escaping () async throws -> Data) async throws -> Data {
        if let d = cache[key] { return d }
        if let t = inFlight[key] { return try await t.value }
        let task = Task { try await make() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let data = try await task.value
        cache[key] = data
        cacheOrder.append(key)
        while cacheOrder.count > 10 { cache[cacheOrder.removeFirst()] = nil }
        return data
    }

    // MARK: - Video

    private func makeVideoSegment(_ n: Int) async throws -> Data {
        let v = info.video
        let start = info.boundaries[n], end = info.boundaries[n + 1]
        var args = ["-nostdin", "-v", "error"]

        if v.canCopy {
            args += ["-ss", (start + 0.001).ff, "-t", (end - start + 1.5).ff, "-i", info.url.path,
                     "-map", "0:\(v.index)", "-c:v", "copy"]
            if v.codec == "h264" {
                args += ["-tag:v", "avc1"]
            } else {
                args += ["-tag:v", v.dvProfile == 5 ? "dvh1" : "hvc1"]
                if v.dvProfile == 5 || v.dvProfile == 8 { args += ["-strict", "unofficial"] }
            }
        } else {
            let frames = Int(((end - start) * v.frameRate).rounded())
            let bitrate = max(3_000_000, Int(Double(v.width * v.height) * v.frameRate / 8))
            args += ["-ss", max(0, start - 0.25 / v.frameRate).ff, "-i", info.url.path,
                     "-map", "0:\(v.index)", "-frames:v", "\(frames)",
                     "-c:v", "h264_videotoolbox", "-b:v", "\(bitrate)", "-maxrate", "\(bitrate * 2)",
                     "-bufsize", "\(bitrate * 2)", "-profile:v", "high", "-pix_fmt", "yuv420p",
                     "-bf", "0", "-g", "\(frames + 1)"]
        }
        args += ["-an", "-sn", "-dn", "-f", "mp4",
                 "-movflags", "+frag_keyframe+empty_moov+default_base_moof+negative_cts_offsets",
                 "-use_editlist", "0", "-"]

        let out = try await Tools.run(ffmpeg, args)
        let parsed = try MP4.parse(out)
        if inits["v"] == nil { inits["v"] = parsed.initSegment }

        let ts = Double(parsed.timescale)
        let limit = UInt64(((end - start) - 0.001) * ts)
        let first = parsed.fragments.first?.baseDecodeTime ?? 0
        let keep = parsed.fragments.filter { $0.baseDecodeTime - first < limit }
        // The keyframe's pts must equal the source pts, so its dts sits one composition offset earlier.
        let firstDTS = Int64((start * ts).rounded()) - (keep.first?.firstCompositionOffset ?? 0)
        return MP4.retime(out, fragments: keep, startTime: UInt64(max(0, firstDTS)),
                          sequenceBase: UInt32(n * 1000 + 1))
    }

    // MARK: - Copied audio

    /// Index of the first audio frame whose pts is >= t.
    private func frameIndex(_ t: AudioTrack, _ time: Double, last: Bool) -> Int {
        let raw = (time - t.firstPTS) / t.frameDuration
        return max(0, Int((last ? raw : raw - 0.001).rounded(.up)))
    }

    private func makeCopiedAudioSegment(_ a: Int, _ n: Int) async throws -> Data {
        let t = info.audio[a]
        let last = n + 1 == info.segmentCount
        let tStart = t.firstPTS + Double(frameIndex(t, info.boundaries[n], last: false)) * t.frameDuration
        let tEnd = t.firstPTS + Double(frameIndex(t, info.boundaries[n + 1], last: last)) * t.frameDuration
        let seek = max(0, tStart - 1.0)
        let half = t.frameDuration / 2

        var args = ["-nostdin", "-v", "error", "-copyts"]
        if seek > 0 { args += ["-ss", seek.ff] }
        args += ["-t", (tEnd - seek + 1.0).ff, "-i", info.url.path, "-map", "0:\(t.index)", "-c:a", "copy",
                 "-vn", "-sn", "-dn"]
        if tStart - half > 0 { args += ["-ss", (tStart - half).ff] }
        if !last { args += ["-to", (tEnd - half).ff] }
        args += ["-f", "mp4", "-movflags", "+delay_moov+default_base_moof", "-frag_duration", "1000000000",
                 "-use_editlist", "0", "-"]

        let out = try await Tools.run(ffmpeg, args)
        let parsed = try MP4.parse(out)
        if inits["a\(a)"] == nil { inits["a\(a)"] = parsed.initSegment }
        return MP4.retime(out, fragments: parsed.fragments,
                          startTime: UInt64((tStart * Double(parsed.timescale)).rounded()),
                          sequenceBase: UInt32(n * 1000 + 1))
    }

    // MARK: - Transcoded audio

    private func job(for a: Int, segment n: Int, restartIfFar: Bool) async throws -> AudioJob {
        if let job = jobs[a] {
            let produced = job.lastProduced()
            let near = n >= job.startSegment && n <= max(produced, job.startSegment) + 10
            if !restartIfFar || (near && !job.failed) { return job }
            job.stop()
        }
        let job = try AudioJob(info: info, track: info.audio[a], startSegment: n, ffmpeg: ffmpeg,
                               dir: workDir.appendingPathComponent("audio\(a)-\(n)"))
        jobs[a] = job
        return job
    }
}

/// Transcodes one audio track to E-AC-3 (multichannel) or AAC (stereo) as a continuous ffmpeg run,
/// writing HLS segments to disk. Restarted at the requested segment when the player seeks far away.
final class AudioJob: @unchecked Sendable {
    let startSegment: Int
    let dir: URL
    private let process = Process()
    private let padding: Int64
    private(set) var failed = false

    static func codec(for track: AudioTrack) -> String { track.channels > 2 ? "ec-3" : "mp4a.40.2" }

    init(info: MediaInfo, track: AudioTrack, startSegment: Int, ffmpeg: String, dir: URL) throws {
        self.startSegment = startSegment
        self.dir = dir
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let len = Segmenter.audioJobSegment
        let surround = track.channels > 2
        padding = surround ? 256 : 2112
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-nostdin", "-v", "error", "-ss", (Double(startSegment) * len).ff,
                             "-i", info.url.path, "-map", "0:\(track.index)", "-vn", "-sn", "-dn",
                             "-c:a", surround ? "eac3" : "aac_at", "-b:a", surround ? "640k" : "256k",
                             "-ac", surround ? "6" : "2", "-ar", "48000",
                             "-f", "hls", "-hls_time", len.ff, "-hls_segment_type", "fmp4",
                             "-hls_list_size", "0", "-hls_playlist_type", "event",
                             "-start_number", "\(startSegment)",
                             "-hls_fmp4_init_filename", "init.mp4",
                             "-hls_segment_filename", dir.appendingPathComponent("s%d.m4s").path,
                             dir.appendingPathComponent("list.m3u8").path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] p in
            if p.terminationStatus != 0 && p.terminationReason == .exit { self?.failed = true }
        }
        try process.run()
    }

    func stop() {
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Highest segment number listed in the job's playlist (i.e. fully written), or -1.
    func lastProduced() -> Int {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("list.m3u8"), encoding: .utf8) else { return -1 }
        return text.split(separator: "\n").compactMap { line -> Int? in
            guard line.hasPrefix("s"), line.hasSuffix(".m4s") else { return nil }
            return Int(line.dropFirst().dropLast(4))
        }.max() ?? -1
    }

    func initSegment() async throws -> Data {
        let url = dir.appendingPathComponent("init.mp4")
        try await waitUntil { FileManager.default.fileExists(atPath: url.path) && self.lastProduced() >= self.startSegment }
        return try Data(contentsOf: url)
    }

    func segment(_ n: Int) async throws -> Data {
        try await waitUntil { self.lastProduced() >= n }
        let data = try Data(contentsOf: dir.appendingPathComponent("s\(n).m4s"))
        let fragments = MP4.boxes(data).enumerated().compactMap { i, box -> MP4.Fragment? in
            guard box.type == "moof", let tfdt = MP4.find(data, ["moof", "traf", "tfdt"], in: box.range) else { return nil }
            let q = tfdt.payload.lowerBound
            let base = data[q] == 1 ? data.u64(q + 4) : UInt64(data.u32(q + 4))
            let next = MP4.boxes(data, in: box.range.upperBound..<data.count).first
            return MP4.Fragment(range: box.range.lowerBound..<(next?.range.upperBound ?? data.count), baseDecodeTime: base)
        }
        let start = max(0, Int64((Double(n) * Segmenter.audioJobSegment * 48000).rounded()) - padding)
        return MP4.retime(data, fragments: fragments, startTime: UInt64(start), sequenceBase: UInt32(n * 1000 + 1))
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            if failed { throw ToolError(message: "audio transcoding failed") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw ToolError(message: "timed out waiting for audio segment")
    }
}
