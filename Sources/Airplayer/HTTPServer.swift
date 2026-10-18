import Foundation
import Network

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
}

struct HTTPResponse {
    var status: Int = 200
    var contentType: String = "application/octet-stream"
    var body: Data = Data()

    static func text(_ s: String, type: String) -> HTTPResponse { HTTPResponse(contentType: type, body: Data(s.utf8)) }
    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain", body: Data(message.utf8))
    }
}

/// A small keep-alive HTTP/1.1 server reachable from the LAN (the TV fetches segments from it).
final class HTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let listener: NWListener
    private let queue = DispatchQueue(label: "http")
    private let handler: Handler
    var log: (@Sendable (String) -> Void)?

    init(port: UInt16 = 0, handler: @escaping Handler) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        self.handler = handler
    }

    /// Starts listening and returns the bound port.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { [listener] state in
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; cont.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let e): resumed = true; cont.resume(throwing: e)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.start(queue: queue)
        }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
                let rest = Data(buf[end.upperBound...])
                Task { await self.respond(conn, head: head, rest: rest) }
            } else if complete || error != nil || buf.count > 1_000_000 {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    private func respond(_ conn: NWConnection, head: String, rest: Data) async {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { conn.cancel(); return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let rawPath = String(parts[1]).components(separatedBy: "?")[0]
        let request = HTTPRequest(method: String(parts[0]), path: rawPath.removingPercentEncoding ?? rawPath, headers: headers)

        let started = Date()
        var response = await handler(request)
        var extra = ["Accept-Ranges: bytes"]
        var body = response.body

        if response.status == 200, let range = headers["range"], let r = Self.parseRange(range, length: body.count) {
            extra.append("Content-Range: bytes \(r.lowerBound)-\(r.upperBound - 1)/\(body.count)")
            body = body.subdata(in: r)
            response.status = 206
        }
        let keepAlive = headers["connection"]?.lowercased() != "close"
        var header = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        header += "Content-Type: \(response.contentType)\r\nContent-Length: \(body.count)\r\n"
        header += "Access-Control-Allow-Origin: *\r\nCache-Control: no-cache\r\n"
        header += extra.map { "\($0)\r\n" }.joined()
        header += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"

        var payload = Data(header.utf8)
        if request.method != "HEAD" { payload.append(body) }

        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let client: String
        if case .hostPort(let host, _) = conn.endpoint { client = "\(host)" } else { client = "?" }
        log?("\(client) \(request.method) \(request.path) → \(response.status) \(ByteCountFormatter.string(fromByteCount: Int64(body.count), countStyle: .file)) \(ms)ms")

        conn.send(content: payload, completion: .contentProcessed { [weak self] _ in
            if keepAlive { self?.receive(conn, buffer: rest) } else { conn.cancel() }
        })
    }

    static func parseRange(_ header: String, length: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes="), length > 0 else { return nil }
        let spec = header.dropFirst(6).split(separator: ",")[0].split(separator: "-", omittingEmptySubsequences: false)
        guard spec.count == 2 else { return nil }
        if spec[0].isEmpty, let suffix = Int(spec[1]) { return max(0, length - suffix)..<length }
        guard let start = Int(spec[0]), start < length else { return nil }
        let end = Int(spec[1]).map { min($0, length - 1) } ?? length - 1
        return start <= end ? start..<(end + 1) : nil
    }

    static func reason(_ status: Int) -> String {
        [200: "OK", 206: "Partial Content", 404: "Not Found", 500: "Internal Server Error"][status] ?? "OK"
    }

    /// IPv4 address of the active Wi-Fi/Ethernet interface (VPN tunnels are skipped: the TV can't reach them).
    static func lanAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var candidates: [(name: String, ip: String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            let name = String(cString: ifa.ifa_name)
            if ip.hasPrefix("169.254.") { continue }
            candidates.append((name, ip))
        }
        return (candidates.first { $0.name.hasPrefix("en") } ?? candidates.first { !$0.name.hasPrefix("utun") })?.ip
    }
}
