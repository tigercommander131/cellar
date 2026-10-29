import CryptoKit
import Foundation

/// Settings and session facts kept in `state.json`.
public struct CellarState: Codable, Sendable, Equatable {
    /// nil = decide from RAM (on for 8 GB Macs).
    public var lowMemoryMode: Bool?
    public var steamSession: SteamSession?
    /// Default for games whose profile doesn't say: show the Metal performance overlay.
    public var showFPS: Bool?
    /// When each game was last started from Cellar.
    public var lastPlayed: [String: Date]?

    public struct SteamSession: Codable, Sendable, Equatable {
        public var fingerprint: String
        public var backend: GraphicsBackend
        public var started: Date
    }

    public init() {}
}

/// The front door for the app and the CLI: setup, Steam and games.
public struct CellarCore: Sendable {
    public let paths: CellarPaths
    public static let steamBottleName = "steam"

    public init(paths: CellarPaths = CellarPaths()) { self.paths = paths }

    public var packs: PackStore { PackStore(paths: paths) }
    public var profiles: ProfileStore { ProfileStore(paths: paths) }
    public var runtimes: RuntimeBuilder { RuntimeBuilder(paths: paths) }
    public var steamBottle: Bottle { Bottle(paths: paths, name: Self.steamBottleName) }
    public var steam: Steam { Steam(bottle: steamBottle) }

    // MARK: State

    public func loadState() -> CellarState {
        guard let data = try? Data(contentsOf: paths.state) else { return CellarState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(CellarState.self, from: data)) ?? CellarState()
    }

    public func saveState(_ state: CellarState) throws {
        try paths.ensureLayout()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: paths.state, options: .atomic)
    }

    public func lowMemoryMode(host: HostCheck = .current()) -> Bool {
        loadState().lowMemoryMode ?? host.prefersLowMemoryMode
    }

    public func log(_ name: String) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return paths.logs.appending(path: "\(name)-\(stamp).log")
    }

    /// Deletes logs older than a week.
    public func pruneLogs() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        guard let files = try? fm.contentsOfDirectory(at: paths.logs, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files {
            if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }

    // MARK: Setup

    public enum SetupStep: String, Sendable, CaseIterable {
        case checks, engine, graphics, bottle, steam, done
    }

    public var isSetUp: Bool {
        packs.installed(.engine) != nil && steamBottle.exists && steam.isInstalled
    }

    /// Installs whatever is missing or out of date. Safe to run again.
    public func setup(manifest: PackManifest,
                      step: @Sendable (SetupStep) -> Void = { _ in },
                      progress: @escaping @Sendable (String, Double?) -> Void = { _, _ in }) async throws {
        try paths.ensureLayout()
        pruneLogs()
        packs.removeLeftovers()
        step(.checks)
        let host = HostCheck.current(volume: paths.root)
        if !host.rosettaInstalled {
            progress("Installing Rosetta 2…", nil)
            try HostCheck.installRosetta()
        }
        let problems = HostCheck.current(volume: paths.root).problems
        guard problems.isEmpty else { throw CellarError(problems.joined(separator: "\n")) }

        for kind in [PackKind.engine, .dxmt, .d3dmetal, .profiles] {
            step(kind == .engine ? .engine : (kind == .profiles ? .graphics : .graphics))
            guard let entry = manifest.entry(kind) else { continue }
            if packs.isCurrent(entry) { continue }
            if kind == .engine || kind == .d3dmetal { stopEverything() }
            let label = Self.label(kind)
            progress("Downloading \(label)…", 0)
            try await packs.install(entry) { fraction in progress("Downloading \(label)…", fraction) }
        }

        step(.bottle)
        progress("Creating the Windows environment…", nil)
        let engine = try runtimes.prepare(.wined3d)
        try steamBottle.create(engine: engine, log: log("setup"))

        step(.steam)
        if !steam.isInstalled {
            progress("Installing Steam…", nil)
            try await steam.install(engine: engine, log: log("steam-install"))
        }
        // Build the backend copies now so the first Play is quick.
        for backend in [GraphicsBackend.d3dmetal, .dxmt] where packs.installed(backend == .dxmt ? .dxmt : .d3dmetal) != nil {
            _ = try runtimes.prepare(backend)
        }
        step(.done)
    }

    static func label(_ kind: PackKind) -> String {
        switch kind {
        case .engine: "the Wine engine"
        case .dxmt: "DXMT"
        case .d3dmetal: "D3DMetal"
        case .profiles: "game fixes"
        }
    }

    // MARK: Steam and games

    public func runningProcesses() -> [WineProcess] {
        ProcessSnapshot.wineProcesses(under: paths.packs)
    }

    public func isSteamRunning() -> Bool {
        runningProcesses().contains { $0.windowsName.lowercased() == "steam.exe" }
    }

    /// Windows programs other than Steam's own helpers and Wine's services.
    public func runningGames() -> [WineProcess] {
        let ignored: Set<String> = ["steam.exe", "steamwebhelper.exe", "steamservice.exe", "steamerrorreporter.exe",
                                    "services.exe", "winedevice.exe", "plugplay.exe", "explorer.exe", "svchost.exe",
                                    "rpcss.exe", "conhost.exe", "start.exe", "wineboot.exe", "tabtip.exe", "wine",
                                    "wine-preloader", "wineserver", "gameoverlayui.exe", "gameoverlayui64.exe"]
        return runningProcesses().filter { !ignored.contains($0.windowsName.lowercased()) }
    }

    public func launchConfig(for profile: GameProfile?) -> LaunchConfig {
        let profile = profile ?? GameProfile(appId: "")
        var config = LaunchConfig(backend: profile.backend)
        config.metalHUD = profile.metalHUD ?? loadState().showFPS ?? false
        config.extraEnvironment = profile.env ?? [:]
        config.dllOverrides = profile.dllOverrides ?? [:]
        return config
    }

    /// Steam hands its environment to every game it starts, so the fingerprint of that
    /// environment decides whether a running Steam can launch a game as-is.
    public func fingerprint(_ config: LaunchConfig, engine: URL) -> String {
        let env = steamBottle.wine(engine: engine).environment(config)
        let managed = env.filter { key, _ in Wine.strippedPrefixes.contains { key.hasPrefix($0) } }
        let text = managed.keys.sorted().map { "\($0)=\(managed[$0]!)" }.joined(separator: "\n") + "\n" + engine.path
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Opens Steam, plays or installs a game. Restarts Steam if it runs with the wrong settings.
    public func launchSteam(_ mode: Steam.Mode) throws {
        guard steam.isInstalled else { throw CellarError("Steam isn't installed yet. Run setup first.") }
        let appId: String? = {
            switch mode {
            case .play(let id, _), .install(let id): id
            default: nil
            }
        }()
        let profile = appId.map { profiles.profile(for: $0) }
        if case .play = mode, let need = profile?.minRAMGB, HostCheck.current().memoryGB < need {
            // The UI warns before calling this; the CLI just notes it.
            FileHandle.standardError.write(Data("Note: this game wants \(need) GB of memory.\n".utf8))
        }
        var config = launchConfig(for: profile)
        if case .play = mode {} else if isSteamRunning(), let session = loadState().steamSession {
            // Opening or installing never needs a restart; keep what's running.
            config.backend = session.backend
        }
        let engine = try runtimes.prepare(config.backend)
        let fp = fingerprint(config, engine: engine)
        var state = loadState()

        if isSteamRunning() {
            if state.steamSession?.fingerprint != fp, case .play = mode {
                let games = runningGames()
                guard games.isEmpty else {
                    throw CellarError("Close \(games.map(\.windowsName).joined(separator: ", ")) first: Steam has to restart with this game's settings.")
                }
                stopSteam(engine: engine)
            }
        }

        try steamBottle.prepare(for: config.backend)
        if let profile {
            var values = profile.registry ?? []
            if let retina = profile.retina { values.append(.retina(retina)) }
            if !isSteamRunning(), !values.isEmpty {
                try steamBottle.importRegistry(values, engine: engine, log: log("registry"))
            }
        }
        steam.clearStaleLocks()

        let wine = steamBottle.wine(engine: engine)
        var finalMode = mode
        if case .play(let id, let extra) = mode { finalMode = .play(appID: id, args: extra + (profile?.gameArgs ?? [])) }
        let finalArgs = Steam.arguments(finalMode, steamArgs: profile?.steamArgs ?? [], lowMemory: lowMemoryMode())
        if !isSteamRunning() {
            state.steamSession = .init(fingerprint: fp, backend: config.backend, started: Date())
        }
        if case .play(let id, _) = mode { state.lastPlayed = (state.lastPlayed ?? [:]).merging([id: Date()]) { $1 } }
        try saveState(state)
        _ = try wine.start(finalArgs, config: config, log: log("steam"), workingDirectory: steam.steamDir)
    }

    public func stopSteam(engine: URL? = nil) {
        let engine = engine ?? paths.pack(.engine)
        steamBottle.wine(engine: engine).kill()
        var state = loadState()
        state.steamSession = nil
        try? saveState(state)
    }

    /// Force-quits every Windows program Cellar started.
    public func stopEverything() {
        if FileManager.default.fileExists(atPath: paths.pack(.engine).path) {
            stopSteam()
        }
        for process in runningProcesses() { kill(process.pid, SIGKILL) }
    }

    /// Runs a Windows program directly in the Steam bottle (installers, tools, tests).
    public func run(exe: URL, args: [String], backend: GraphicsBackend, wait: Bool) throws -> Int32? {
        let engine = try runtimes.prepare(backend)
        try steamBottle.prepare(for: backend)
        let wine = steamBottle.wine(engine: engine)
        let config = LaunchConfig(backend: backend)
        let all = [wine.windowsPath(exe)] + args
        if wait { return try wine.run(all, config: config, log: log("run"), timeout: 24 * 3600, workingDirectory: exe.deletingLastPathComponent()) }
        _ = try wine.start(all, config: config, log: log("run"), workingDirectory: exe.deletingLastPathComponent())
        return nil
    }
}
