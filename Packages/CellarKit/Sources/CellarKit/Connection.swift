import Foundation

/// How Cellar decides between Steam's online and offline modes.
public enum ConnectionMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Cellar checks the network and picks. The default.
    case automatic
    case online
    case offline
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .online: "Online"
        case .offline: "Offline"
        }
    }

    /// Whether Steam should start in offline mode, given what the network check found.
    public func wantsOffline(_ reachability: SteamReachability) -> Bool {
        switch self {
        case .online: false
        case .offline: true
        case .automatic: reachability != .reachable
        }
    }
}

public enum SteamReachability: String, Sendable, Equatable {
    /// A real Steam connection server answered.
    case reachable
    /// The internet works, but Steam's servers don't answer (school Wi-Fi, a sign-in page).
    case blocked
    case noInternet
}

/// Checks whether Steam can really connect from this network: asks Steam for its connection servers,
/// then opens the same kind of WebSocket the client uses. A web page loading isn't enough, because
/// networks that block Steam often leave its website alone.
public enum SteamConnectivity {
    static let directory = URL(string: "https://api.steampowered.com/ISteamDirectory/GetCMListForConnect/v1/?cellid=0")!
    static let internetCheck = URL(string: "https://www.apple.com/library/test/success.html")!

    public static func probe(timeout: TimeInterval = 5) async -> SteamReachability {
        // Lets the whole flow be tried without changing networks.
        switch ProcessInfo.processInfo.environment["CELLAR_SIMULATE_NETWORK"] {
        case "blocked": return .blocked
        case "none": return .noInternet
        case "reachable": return .reachable
        default: break
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        if let (data, response) = try? await session.data(from: directory),
           (response as? HTTPURLResponse)?.statusCode == 200 {
            let hosts = connectionServers(fromDirectory: data)
            if hosts.isEmpty { return .reachable }   // Steam answered but changed its format: don't block on that.
            if await anyAnswers(hosts: Array(hosts.prefix(4)), timeout: timeout) { return .reachable }
            return .blocked
        }
        if (try? await session.data(from: internetCheck)) != nil { return .blocked }
        return .noInternet
    }

    /// WebSocket servers from Steam's directory, port 443 first since networks rarely block it.
    static func connectionServers(fromDirectory data: Data) -> [String] {
        struct Response: Decodable {
            struct Body: Decodable { var serverlist: [Server]? }
            struct Server: Decodable {
                var endpoint: String?
                var type: String?
            }
            var response: Body
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        let hosts = (decoded.response.serverlist ?? []).filter { $0.type == "websockets" }.compactMap(\.endpoint)
        return hosts.filter { $0.hasSuffix(":443") } + hosts.filter { !$0.hasSuffix(":443") }
    }

    static func anyAnswers(hosts: [String], timeout: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            for host in hosts { group.addTask { await opens(host: host, timeout: timeout) } }
            for await opened in group where opened {
                group.cancelAll()
                return true
            }
            return false
        }
    }

    static func opens(host: String, timeout: TimeInterval) async -> Bool {
        guard let url = URL(string: "wss://\(host)/cmsocket/") else { return false }
        let probe = SocketProbe()
        return await probe.run(url: url, timeout: timeout)
    }

    private final class SocketProbe: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        func run(url: URL, timeout: TimeInterval) async -> Bool {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let task = session.webSocketTask(with: url)
            return await withCheckedContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                task.resume()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in finish(false) }
            }
        }

        private func finish(_ result: Bool) {
            lock.withLock {
                continuation?.resume(returning: result)
                continuation = nil
            }
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
            finish(true)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            finish(false)
        }
    }
}

/// What Steam's own connection log says about the current session.
public enum SteamLogonState: Equatable, Sendable {
    /// No connection attempts since `since`.
    case idle
    /// Attempts started at this time, and no connection has been made.
    case tryingSince(Date)
    /// A connection was made, but sign-in hasn't finished (or needs the user).
    case connected
    case loggedOn
}

extension Steam {
    var connectionLog: URL { steamDir.appending(path: "logs/connection_log.txt") }

    public func logonState(since: Date) -> SteamLogonState {
        guard let handle = try? FileHandle(forReadingFrom: connectionLog) else { return .idle }
        defer { try? handle.close() }
        // Only the end matters, and the log grows for as long as Steam keeps it.
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 400_000 ? size - 400_000 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        return Self.logonState(log: text, since: since)
    }

    /// Reads `[2026-11-02 02:11:54] [Logged On, 4, 7] ...` lines written at or after `since`.
    static func logonState(log: String, since: Date) -> SteamLogonState {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var firstAttempt: Date?
        var state = SteamLogonState.idle
        // Steam writes Windows line endings, which Swift counts as one character, not as "\n".
        for line in log.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("["), line.count > 21,
                  let date = formatter.date(from: String(line.dropFirst().prefix(19))), date >= since else { continue }
            if line.contains("RecvMsgClientLogOnResponse() : processing complete") || line.contains("[Logged On,") {
                state = .loggedOn
            } else if line.contains("Logged Off") || line.contains("LogOff()") {
                firstAttempt = nil
                state = .idle
            } else if line.contains("ConnectionCompleted()") {
                if state != .loggedOn { state = .connected }
            } else if line.contains("Connect() starting") || line.contains("PingWebSocketCM()") || line.contains("Connecting") {
                if case .connected = state { continue }
                if case .loggedOn = state { continue }
                if firstAttempt == nil { firstAttempt = date }
                state = .tryingSince(firstAttempt ?? date)
            }
        }
        return state
    }
}
