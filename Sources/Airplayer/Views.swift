import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: PlayerModel
    @State private var showLog = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                PlayerViewRepresentable(player: model.player)
                overlay
            }
            .frame(minWidth: 640, minHeight: 360)
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in
                            if SubtitleStore.externalExtensions.contains(url.pathExtension.lowercased()) {
                                model.addSubtitles([url])
                            } else {
                                model.open(url)
                            }
                        }
                    }
                }
                return true
            }
            controls
            if showLog { logView }
        }
        .navigationTitle(model.title)
        .toolbar {
            ToolbarItemGroup {
                Button { openMovie() } label: { Label("Open", systemImage: "folder") }
                    .help("Open a movie (⌘O)")
                Button { openSubtitles() } label: { Label("Add Subtitles", systemImage: "captions.bubble") }
                    .disabled(model.state != .ready)
                    .help("Add external subtitle files")
                Toggle(isOn: $showLog) { Label("Log", systemImage: "list.bullet.rectangle") }
                    .help("Show server log")
                RoutePicker(player: model.player)
                    .frame(width: 32, height: 24)
                    .help("Choose an AirPlay device")
            }
        }
    }

    @ViewBuilder private var overlay: some View {
        switch model.state {
        case .idle:
            VStack(spacing: 12) {
                Image(systemName: "airplayvideo").font(.system(size: 48))
                Text("Drop a movie here or press ⌘O").font(.title3)
                Text("MKV · AVI · MP4 · MOV · 4K HDR / Dolby Vision").foregroundStyle(.secondary)
            }
            .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
        case .loading(let message):
            VStack(spacing: 10) { ProgressView(); Text(message) }
                .padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text(message).multilineTextAlignment(.center).textSelection(.enabled)
            }
            .padding(20).frame(maxWidth: 480).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .ready:
            if model.isAirPlaying {
                VStack(spacing: 8) {
                    Image(systemName: "airplayvideo").font(.system(size: 44))
                    Text("Playing on AirPlay device").font(.title3)
                }
                .foregroundStyle(.white).allowsHitTesting(false)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Picker("Audio", selection: Binding(get: { model.selectedAudio }, set: { model.selectAudio($0) })) {
                ForEach(model.audioOptions) { Text($0.name).tag($0.id) }
            }
            .frame(maxWidth: 420)
            .disabled(model.audioOptions.isEmpty)

            Picker("Subtitles", selection: Binding(get: { model.selectedSubtitle }, set: { model.selectSubtitle($0) })) {
                Text("Off").tag(-1)
                ForEach(model.subtitleOptions) { Text($0.name).tag($0.id) }
            }
            .frame(maxWidth: 320)
            .disabled(model.subtitleOptions.isEmpty)

            Spacer()
            Text(model.trackSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { i, line in
                        Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(i)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .frame(height: 160)
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: model.log.count) { _, count in proxy.scrollTo(count - 1, anchor: .bottom) }
        }
    }

    func openMovie() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi]
            + ["mkv", "webm", "ts", "m2ts", "wmv", "flv"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url { model.open(url) }
    }

    func openSubtitles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = SubtitleStore.externalExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK { model.addSubtitles(panel.urls) }
    }
}

struct PlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

struct RoutePicker: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = player            // on macOS this makes the picker offer video (AirPlay TV) routes
        view.isRoutePickerButtonBordered = false
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {}
}
