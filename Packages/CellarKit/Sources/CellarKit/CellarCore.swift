import CryptoKit
import Foundation

/// Settings and session facts kept in `state.json`.
public struct CellarState: Codable, Sendable, Equatable {
    /// Keep Steam's window closed while a game runs (nil means on). It draws on the CPU, so this
    /// frees CPU, memory and battery.
    public var hideSteamWhilePlaying: Bool?
    /// Don't ask about the Battery preset when pressing Play unplugged.
    public var skipBatteryPrompt: Bool?
    /// The Retina setting last written to the bottle (nil means off).
    public var retina: Bool?
    public var steamSession: SteamSession?
    /// Default for games whose profile doesn't say: show the Metal performance overlay.
    public var showFPS: Bool?
    /// When each game was last started from Cellar.
    public var lastPlayed: [String: Date]?
    /// nil means automatic.
    public var connectionMode: ConnectionMode?
    /// How each game has gone on this Mac, for the Will It Run badges.
    public var gameStats: [String: GameStats]?
    /// The player's own verdict on a game.
    public var compatibilityReports: [String: Bool]?
    /// Add every installed game to `~/Applications/Cellar Games`, so Spotlight finds it (nil means on).
    public var gamesInSpotlight: Bool?
    /// Seconds a saved clip goes back (nil means 30).
    public var clipSeconds: Int?
    /// Start Clips by themselves when a game starts (nil means on).
    public var autoClips: Bool?
    /// Retry a game on another graphics option if it closes right after starting (nil means on).
    public var selfFixGames: Bool?
    /// Keep Cellar's icon in the menu bar (nil means on).
    public var menuBarIcon: Bool?
    /// Get beta versions of Cellar (nil means off).
    public var betaUpdates: Bool?

    public struct GameStats: Codable, Sendable, Equatable {
        public var playedSeconds: Double = 0
        public var quickExits: Int = 0
        public init() {}

        /// A launch that closes within this many seconds counts as not having started.
        public static let quickExitSeconds: Double = 20

        public mutating func record(sessionSeconds: Double) {
            if sessionSeconds < Self.quickExitSeconds {
                quickExits += 1
            } else {
                playedSeconds += sessionSeconds
                quickExits = 0
            }
        }
    }

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

    public var hideSteamWhilePlaying: Bool { loadState().hideSteamWhilePlaying ?? true }

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
        ProcessSnapshot.wineProcesses(paths: paths)
    }

    public func isSteamRunning() -> Bool {
        runningProcesses().contains { $0.windowsName.lowercased() == "steam.exe" }
    }

    /// Windows programs other than Steam's own helpers and Wine's services.
    public func runningGames() -> [WineProcess] {
        let ignored: Set<String> = ["steam.exe", "steamwebhelper.exe", "steamservice.exe", "steamerrorreporter.exe",
                                    "services.exe", "winedevice.exe", "plugplay.exe", "explorer.exe", "svchost.exe",
                                    "rpcss.exe", "conhost.exe", "start.exe", "wineboot.exe", "tabtip.exe", "wine",
                                    "wine-preloader", "wineserver", "gameoverlayui.exe", "gameoverlayui64.exe",
                                    "cellar-bridge.exe"]
        return runningProcesses().filter { !ignored.contains($0.windowsName.lowercased()) }
    }

    /// Which of `apps` have a program running from their install folder right now.
    public func runningAppIDs(among apps: [SteamApp]) -> Set<String> {
        Steam.appIDs(apps, runningFrom: runningGames().map(\.windowsPath))
    }

    public func launchConfig(for profile: GameProfile?, preset: GamePreset? = nil) -> LaunchConfig {
        let profile = profile ?? GameProfile(appId: "")
        var config = LaunchConfig(backend: profile.backend)
        config.metalHUD = profile.metalHUD ?? loadState().showFPS ?? false
        config.extraEnvironment = profile.env ?? [:]
        // Not read by Wine; part of the settings fingerprint so Steam restarts when Retina changes.
        if profile.retina == true { config.extraEnvironment["CELLAR_RETINA"] = "1" }
        config.dllOverrides = profile.dllOverrides ?? [:]
        if profile.steamOverlay == true {
            config.dllOverrides["gameoverlayrenderer,gameoverlayrenderer64"] = "n,b"
        }
        // Without a preset or an explicit cap, nothing changes.
        let cap = preset?.frameCap ?? profile.frameCap ?? profile.preset?.frameCap ?? 0
        if cap > 0, config.backend.supportsFrameCap {
            config.extraEnvironment["DXMT_CONFIG"] = "d3d11.preferredMaxFrameRate=\(cap);"
        }
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
    /// `preset` applies to this launch only (the Battery prompt uses it).
    public func launchSteam(_ mode: Steam.Mode, preset: GamePreset? = nil) throws {
        guard steam.isInstalled else { throw CellarError("Steam isn't installed yet. Run setup first.") }
        let appId: String? = {
            switch mode {
            case .play(let id, _), .install(let id), .join(let id, _): id
            default: nil
            }
        }()
        // Playing or joining starts a game, which inherits Steam's settings.
        let startsGame: Bool = {
            switch mode {
            case .play, .join: true
            default: false
            }
        }()
        let profile = appId.map { profiles.profile(for: $0) }
        if startsGame, let need = profile?.minRAMGB, HostCheck.current().memoryGB < need {
            // The UI warns before calling this; the CLI just notes it.
            FileHandle.standardError.write(Data("Note: this game wants \(need) GB of memory.\n".utf8))
        }
        var config = launchConfig(for: profile, preset: preset)
        if !startsGame, isSteamRunning(), let session = loadState().steamSession {
            // Opening or installing never needs a restart; keep what's running.
            config.backend = session.backend
        }
        let engine = try runtimes.prepare(config.backend)
        let fp = fingerprint(config, engine: engine)
        var state = loadState()

        if isSteamRunning() {
            if state.steamSession?.fingerprint != fp, startsGame {
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
            let retina = profile.retina ?? false
            if retina != (state.retina ?? false) { values.append(.retina(retina)) }
            if !isSteamRunning(), !values.isEmpty {
                try steamBottle.importRegistry(values, engine: engine, log: log("registry"))
                state.retina = retina
            }
        }
        steam.clearStaleLocks()
        if startsGame, profile?.writeSteamAppID == true, let appId { steam.writeSteamAppID(appId) }

        let wine = steamBottle.wine(engine: engine)
        var finalMode = mode
        if case .play(let id, let extra) = mode { finalMode = .play(appID: id, args: extra + (profile?.gameArgs ?? [])) }
        let finalArgs = Steam.arguments(finalMode, steamArgs: profile?.steamArgs ?? [], hideSteam: hideSteamWhilePlaying)
        if !isSteamRunning() {
            state.steamSession = .init(fingerprint: fp, backend: config.backend, started: Date())
        }
        if startsGame, let appId { state.lastPlayed = (state.lastPlayed ?? [:]).merging([appId: Date()]) { $1 } }
        try saveState(state)
        _ = try wine.start(finalArgs, config: config, log: log("steam"), workingDirectory: steam.steamDir)
    }

    /// Switches Steam's offline mode. Steam has to restart for it, so this refuses while a game runs.
    /// Afterwards it starts `mode` if given, otherwise reopens Steam if it was open (in the background
    /// when `quietly` is set).
    public func setSteamOffline(_ offline: Bool, quietly: Bool = false, thenStart mode: Steam.Mode? = nil, preset: GamePreset? = nil) throws {
        let games = runningGames()
        guard games.isEmpty else {
            throw CellarError("Close \(games.map(\.windowsName).joined(separator: ", ")) first: Steam has to restart.")
        }
        let wasRunning = isSteamRunning()
        if wasRunning { stopSteam() }
        try steam.setOfflineMode(offline)
        if let mode {
            try launchSteam(mode, preset: preset)
        } else if wasRunning {
            try launchSteam(quietly ? .silent : .open)
        }
    }

    /// Force-quits the running games and leaves Steam open, so the next launch is quick.
    public func stopGames() {
        for process in runningGames() { kill(process.pid, SIGKILL) }
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
