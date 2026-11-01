import Foundation

/// What `cellar-bridge.exe` reports from the Steam client running in the bottle.
public struct BridgeSnapshot: Decodable, Sendable, Equatable {
    public struct Friend: Decodable, Sendable, Equatable {
        public var id: String
        public var name: String
        /// Steam's persona state: 0 offline, 1 online, 2 busy, 3 away, 4 snooze, 5/6 looking to trade/play.
        public var state: Int
        public var app: Int?
        public var lobby: String?
        public var connect: String?
    }

    public var ok: Bool
    public var error: String?
    public var me: String?
    /// The game the signed-in user is playing (0 for none), and how to join them.
    public var app: Int?
    public var lobby: String?
    public var connect: String?
    public var friends: [Friend]?
}

extension CellarCore {
    /// The helper binary: inside Cellar.app, or `CELLAR_BRIDGE` when run from the CLI.
    static var bridgeBinary: URL? {
        if let override = ProcessInfo.processInfo.environment["CELLAR_BRIDGE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return Bundle.main.url(forResource: "cellar-bridge", withExtension: "exe")
    }

    /// Runs the helper against the running Steam and returns the file it wrote.
    func runBridge(_ arguments: (String) -> [String], environment: [String: String] = [:]) throws -> Data {
        guard isSteamRunning() else { throw CellarError("Steam isn't running.") }
        guard let binary = Self.bridgeBinary else { throw CellarError("Cellar's Steam helper is missing.") }
        let fm = FileManager.default
        let dir = steamBottle.driveC.appending(path: "cellar/bridge", directoryHint: .isDirectory)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let installed = dir.appending(path: "cellar-bridge.exe")
        try? fm.removeItem(at: installed)
        try fm.copyItem(at: binary, to: installed)

        let output = dir.appending(path: "out-\(UUID().uuidString.prefix(8)).json")
        defer { try? fm.removeItem(at: output) }
        let backend = loadState().steamSession?.backend ?? .d3dmetal
        let wine = steamBottle.wine(engine: try runtimes.prepare(backend))
        let args = [wine.windowsPath(installed)] + arguments(wine.windowsPath(output))
        try wine.run(args, config: LaunchConfig(backend: backend, extraEnvironment: environment), timeout: 30)
        return try Data(contentsOf: output)
    }

    /// Friends, their games and how to join them, straight from the Steam client.
    public func bridgeSnapshot() throws -> BridgeSnapshot {
        let snapshot = try JSONDecoder().decode(BridgeSnapshot.self, from: runBridge { ["friends", $0] })
        guard snapshot.ok else { throw CellarError(snapshot.error ?? "Steam's friends list isn't available.") }
        return snapshot
    }

    /// Sends a Steam game invite. `connect` is what the friend's game receives when they accept.
    public func invite(friendID: String, appID: String, connect: String) throws {
        struct Result: Decodable { var ok: Bool }
        let data = try runBridge({ ["invite", friendID, connect, $0] }, environment: ["SteamAppId": appID])
        guard try JSONDecoder().decode(Result.self, from: data).ok else {
            throw CellarError("Steam didn't accept the invite.")
        }
    }
}
