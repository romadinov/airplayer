import AVFoundation
import AppKit
import Foundation

@MainActor
final class PlayerModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading(String)
        case ready
        case failed(String)
    }

    struct Option: Identifiable, Hashable {
        let id: Int
        let name: String
    }

    @Published var state: State = .idle
    @Published var title = "Airplayer"
    @Published var audioOptions: [Option] = []
    @Published var subtitleOptions: [Option] = []
    @Published var selectedAudio = 0
    @Published var selectedSubtitle = -1          // -1 = off
    @Published var isAirPlaying = false
    @Published var log: [String] = []
    @Published var trackSummary = ""

    let player = AVPlayer()
    let registry = SessionRegistry()
    private var server: HTTPServer?
    private var baseURL: URL?
    private var session: HLSSession?
    private var movieURL: URL?
    private var audibleGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?
    private var observations: [NSKeyValueObservation] = []

    init() {
        // Leftovers from a previous run (segments, transcoded audio, converted subtitles).
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("Airplayer"))
        player.allowsExternalPlayback = true
        player.appliesMediaSelectionCriteriaAutomatically = false
        observations.append(player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] p, _ in
            Task { @MainActor in self?.isAirPlaying = p.isExternalPlaybackActive }
        })
    }

    private func ensureServer() async throws -> URL {
        if let baseURL { return baseURL }
        let registry = registry
        let server = try HTTPServer { await registry.handle($0) }
        server.log = { [weak self] line in Task { @MainActor in self?.append(line) } }
        let port = try await server.start()
        guard let ip = HTTPServer.lanAddress() else {
            throw ToolError(message: "No Wi-Fi/Ethernet IPv4 address found. The TV must be able to reach this Mac on the local network.")
        }
        self.server = server
        let url = URL(string: "http://\(ip):\(port)")!
        baseURL = url
        append("Server listening on \(url.absoluteString)")
        return url
    }

    func append(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        log.append("\(stamp)  \(line)")
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    // MARK: - Opening

    func open(_ url: URL) {
        Task { await load(url) }
    }

    private func load(_ url: URL) async {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let old = session { registry.remove(old); await old.shutdown() }
        session = nil
        audioOptions = []
        subtitleOptions = []
        title = url.deletingPathExtension().lastPathComponent
        movieURL = url

        do {
            let base = try await ensureServer()
            state = .loading("Reading tracks…")
            let started = Date()
            let info = try await MediaProbe.probe(url)
            append(String(format: "Probed in %.1fs: %d segments, %d audio, %d subtitle tracks", Date().timeIntervalSince(started),
                          info.segmentCount, info.audio.count, info.subtitles.count))
            trackSummary = Self.summary(info)

            let session = try HLSSession(info: info)
            registry.add(session)
            self.session = session
            for sub in SubtitleStore.discover(for: url) {
                await session.addExternalSubtitle(sub, movie: url)
                append("Found external subtitles: \(sub.lastPathComponent)")
            }
            state = .loading("Preparing stream…")
            try await session.prepare()
            if session.info.subtitles.contains(where: { !$0.isText }) {
                append("Note: bitmap subtitles (PGS/VobSub) can't be sent over AirPlay and are hidden.")
            }
            try await playCurrentSession(base: base, at: nil)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
            append("Error: \(error.localizedDescription)")
        }
    }

    func addSubtitles(_ urls: [URL]) {
        guard let session, let movieURL, let base = baseURL else { return }
        Task {
            for url in urls {
                await session.addExternalSubtitle(url, movie: movieURL)
                append("Added subtitles: \(url.lastPathComponent)")
            }
            let time = player.currentTime()
            let wasPlaying = player.rate > 0
            let newSub = session.info.subtitles.filter(\.isText).count - 1
            try? await playCurrentSession(base: base, at: time, play: wasPlaying)
            selectSubtitle(newSub)
        }
    }

    private func playCurrentSession(base: URL, at time: CMTime?, play: Bool = true) async throws {
        guard let session else { return }
        let url = base.appendingPathComponent(session.masterPath)
        append("Playing \(url.absoluteString)")
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 30

        audibleGroup = try await asset.loadMediaSelectionGroup(for: .audible)
        legibleGroup = try await asset.loadMediaSelectionGroup(for: .legible)
        audioOptions = await Self.options(audibleGroup)
        subtitleOptions = await Self.options(legibleGroup)

        player.replaceCurrentItem(with: item)
        if let group = audibleGroup, let def = group.defaultOption ?? group.options.first,
           let idx = group.options.firstIndex(of: def) {
            selectedAudio = idx
            item.select(def, in: group)
        }
        if let group = legibleGroup {
            if selectedSubtitle >= 0, selectedSubtitle < group.options.count {
                item.select(group.options[selectedSubtitle], in: group)
            } else {
                selectedSubtitle = -1
                item.select(nil, in: group)
            }
        }
        if let time { await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) }
        if play { player.play() }
    }

    /// Menu entries named after the playlist's NAME attribute (AVFoundation's displayName is just the language).
    private static func options(_ group: AVMediaSelectionGroup?) async -> [Option] {
        var result: [Option] = []
        for (i, option) in (group?.options ?? []).enumerated() {
            let title = AVMetadataItem.metadataItems(from: option.commonMetadata, filteredByIdentifier: .commonIdentifierTitle).first
            let name = (try? await title?.load(.stringValue)) ?? nil
            result.append(Option(id: i, name: name ?? option.displayName))
        }
        return result
    }

    func selectAudio(_ index: Int) {
        guard let group = audibleGroup, group.options.indices.contains(index) else { return }
        selectedAudio = index
        player.currentItem?.select(group.options[index], in: group)
    }

    func selectSubtitle(_ index: Int) {
        guard let group = legibleGroup else { return }
        selectedSubtitle = group.options.indices.contains(index) ? index : -1
        player.currentItem?.select(selectedSubtitle >= 0 ? group.options[selectedSubtitle] : nil, in: group)
    }

    private static func summary(_ info: MediaInfo) -> String {
        let v = info.video
        var s = "\(v.codec.uppercased()) \(v.width)×\(v.height)"
        if let p = v.dvProfile { s += " · Dolby Vision \(p)" } else if v.range != "SDR" { s += " · \(v.range == "PQ" ? "HDR10" : v.range)" }
        s += v.canCopy ? " · passthrough" : " · re-encoded to H.264"
        let transcoded = info.audio.filter { !$0.canCopy }.count
        if transcoded > 0 { s += " · \(transcoded) audio track(s) transcoded" }
        return s
    }

    func shutdown() {
        if let session { Task { await session.shutdown() } }
    }
}
