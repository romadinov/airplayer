import Foundation

struct ToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Locates and runs the ffmpeg / ffprobe binaries.
enum Tools {
    static let ffmpeg = locate("ffmpeg")
    static let ffprobe = locate("ffprobe")

    static func locate(_ name: String) -> String? {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        if let res = Bundle.main.resourcePath { dirs.insert(res + "/bin", at: 0) }
        return dirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func requireFFmpeg() throws -> (ffmpeg: String, ffprobe: String) {
        guard let ffmpeg, let ffprobe else {
            throw ToolError(message: "ffmpeg/ffprobe not found. Install them with: brew install ffmpeg")
        }
        return (ffmpeg, ffprobe)
    }

    /// Runs a tool and returns its stdout. Throws with stderr on a non-zero exit.
    static func run(_ executable: String, _ arguments: [String]) async throws -> Data {
        try await ProcessGate.shared.acquire()
        defer { Task { await ProcessGate.shared.release() } }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch { cont.resume(throwing: error); return }

                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    cont.resume(returning: outData)
                } else {
                    let msg = String(decoding: errData, as: UTF8.self)
                        .split(separator: "\n").suffix(6).joined(separator: "\n")
                    cont.resume(throwing: ToolError(message: "\((executable as NSString).lastPathComponent) failed: \(msg)"))
                }
            }
        }
    }
}

/// Caps the number of concurrently running ffmpeg/ffprobe processes.
actor ProcessGate {
    static let shared = ProcessGate(limit: 6)
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async throws {
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() }
    }
}

extension Double {
    /// Seconds formatted for ffmpeg command lines.
    var ff: String { String(format: "%.6f", self) }
}
