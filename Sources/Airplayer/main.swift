import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: PlayerModel?
    var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let model { model.open(url) } else { pending.append(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}

struct AirplayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = PlayerModel()

    var body: some Scene {
        Window("Airplayer", id: "main") {
            ContentView(model: model)
                .onAppear {
                    delegate.model = model
                    if let url = delegate.pending.first { model.open(url) }
                    delegate.pending.removeAll()
                }
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { ContentView(model: model).openMovie() }.keyboardShortcut("o")
                Button("Add Subtitles…") { ContentView(model: model).openSubtitles() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}

var retained: [AnyObject] = []

// `Airplayer --serve <file>` runs only the HLS server (handy for testing with other players).
if let i = CommandLine.arguments.firstIndex(of: "--serve"), i + 1 < CommandLine.arguments.count {
    setvbuf(stdout, nil, _IOLBF, 0)
    let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    Task {
        do {
            let registry = SessionRegistry()
            let server = try HTTPServer { await registry.handle($0) }
            server.log = { print($0) }
            let port = try await server.start()
            let info = try await MediaProbe.probe(url)
            let session = try HLSSession(info: info)
            registry.add(session)
            for sub in SubtitleStore.discover(for: url) { await session.addExternalSubtitle(sub, movie: url) }
            try await session.prepare()
            let host = HTTPServer.lanAddress() ?? "127.0.0.1"
            print("READY http://\(host):\(port)\(session.masterPath)")
            print("segments=\(info.segmentCount) audio=\(info.audio.count) subs=\(info.subtitles.count)")
            retained.append(server)
        } catch {
            print("ERROR \(error.localizedDescription)")
            exit(1)
        }
    }
    dispatchMain()
} else {
    AirplayerApp.main()
}
