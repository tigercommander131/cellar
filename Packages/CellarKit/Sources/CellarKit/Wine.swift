import Darwin
import Foundation

/// Everything that decides how one Wine process starts.
public struct LaunchConfig: Sendable, Equatable {
    public var backend: GraphicsBackend
    public var metalHUD: Bool = false
    public var extraEnvironment: [String: String] = [:]
    public var dllOverrides: [String: String] = [:]

    public init(backend: GraphicsBackend, metalHUD: Bool = false, extraEnvironment: [String: String] = [:],
                dllOverrides: [String: String] = [:]) {
        self.backend = backend
        self.metalHUD = metalHUD
        self.extraEnvironment = extraEnvironment
        self.dllOverrides = dllOverrides
    }
}

public struct Wine: Sendable {
    public let paths: CellarPaths
    /// The engine folder (one of `RuntimeBuilder`'s per-backend copies).
    public let engine: URL
    public let bottle: URL

    public init(paths: CellarPaths, engine: URL, bottle: URL) {
        self.paths = paths
        self.engine = engine
        self.bottle = bottle
    }

    public var wine: URL { engine.appending(path: "bin/wine") }
    public var wineserver: URL { engine.appending(path: "bin/wineserver") }

    /// Variables that would leak another Wine setup into ours.
    static let strippedPrefixes = ["WINE", "CELLAR_", "DYLD_", "DXMT_", "MTL_", "D3DM_", "CX_", "ROSETTA_", "MVK_", "GST_", "SDL_"]

    public func environment(_ config: LaunchConfig) -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { key, _ in
            !Self.strippedPrefixes.contains { key.hasPrefix($0) }
        }
        env["WINEPREFIX"] = bottle.path
        env["WINESERVER"] = wineserver.path
        env["WINELOADER"] = wine.path
        env["WINEDEBUG"] = "-all"
        // MSync is fastest on macOS; every process that joins a wineserver must agree on it.
        env["WINEMSYNC"] = "1"
        env["WINEESYNC"] = "0"
        env["ROSETTA_ADVERTISE_AVX"] = "1"
        env["MTL_HUD_ENABLED"] = config.metalHUD ? "1" : "0"
        env["SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS"] = "1"
        // Read by Cellar's engine patch (engine/patches/0001): Steam's Chromium UI only draws
        // under the Mac driver as a single process using software rendering.
        // Read by engine/patches/0002: Steam's background processes don't each get a Dock icon.
        env["CELLAR_NO_DOCK_ICON"] = "steam.exe;steamservice.exe;steamerrorreporter.exe"
        env["CELLAR_STEAMWEBHELPER_FLAGS"] = "--single-process --disable-gpu --disable-gpu-compositing --in-process-gpu"
        env["DYLD_FALLBACK_LIBRARY_PATH"] = engine.appending(path: "lib").path + ":/usr/lib"

        var overrides: [String: String] = [
            "winemenubuilder.exe": "",
            "gameoverlayrenderer,gameoverlayrenderer64": "",
        ]
        switch config.backend {
        case .d3dmetal:
            env["CX_GRAPHICS_BACKEND"] = "d3dmetal"
            env["CX_ACTIVE_GRAPHICS_BACKEND"] = "d3dmetal"
            env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = RuntimeBuilder(paths: paths).libd3dshared().path
            env["D3DM_ENABLE_METALFX"] = "0"
            overrides["dxgi,d3d11,d3d12,d3d10,atidxx64"] = "b"
            overrides["nvngx"] = ""
        case .dxmt:
            env["CX_GRAPHICS_BACKEND"] = "dxmt"
            env["CX_ACTIVE_GRAPHICS_BACKEND"] = "dxmt"
            env["DXMT_LOG_LEVEL"] = "error"
            env["DXMT_SHADER_CACHE_PATH"] = paths.shaders.appending(path: "dxmt").path
            overrides["dxgi,d3d11,d3d10core,winemetal"] = "b"
            overrides["d3d12,nvapi64,nvngx"] = ""
        case .wined3d:
            overrides["nvapi64,nvngx"] = ""
        }
        for (key, value) in config.dllOverrides { overrides[key] = value }
        env["WINEDLLOVERRIDES"] = overrides.keys.sorted().map { "\($0)=\(overrides[$0]!)" }.joined(separator: ";")

        for (key, value) in config.extraEnvironment {
            if value.isEmpty { env.removeValue(forKey: key) } else { env[key] = value }
        }
        return env
    }

    /// Runs a Wine command and waits, killing it after `timeout`. Output goes to `log`.
    @discardableResult
    public func run(_ arguments: [String], config: LaunchConfig, log: URL? = nil,
                    timeout: TimeInterval = 600, workingDirectory: URL? = nil) throws -> Int32 {
        let process = try start(arguments, config: config, log: log, workingDirectory: workingDirectory)
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                Thread.sleep(forTimeInterval: 2)
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                kill(wait: false)
                throw CellarError("wine \(arguments.first ?? "") timed out after \(Int(timeout)) s.")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return process.terminationStatus
    }

    /// Starts a Wine process without waiting. Stdout and stderr are appended to `log`.
    public func start(_ arguments: [String], config: LaunchConfig, log: URL? = nil,
                      workingDirectory: URL? = nil) throws -> Process {
        guard FileManager.default.isExecutableFile(atPath: wine.path) else {
            throw CellarError("Wine isn't installed at \(engine.path).")
        }
        let process = Process()
        process.executableURL = wine
        process.arguments = arguments
        process.environment = environment(config)
        process.currentDirectoryURL = workingDirectory ?? bottle
        let output = try log.map { try Self.appendHandle($0) } ?? FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// Stops every Wine process in this bottle.
    public func kill(wait: Bool = true) {
        var env = environment(LaunchConfig(backend: .wined3d))
        env["WINEPREFIX"] = bottle.path
        _ = try? Shell.run(wineserver.path, ["-k"], environment: env)
        if wait { _ = try? Shell.run(wineserver.path, ["-w"], environment: env) }
    }

    /// Waits until the bottle's wineserver has exited (all its programs closed).
    public func waitForServer() {
        var env = environment(LaunchConfig(backend: .wined3d))
        env["WINEPREFIX"] = bottle.path
        _ = try? Shell.run(wineserver.path, ["-w"], environment: env)
    }

    static func appendHandle(_ url: URL) throws -> FileHandle {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }

    /// Converts a Mac path inside the bottle to the Windows path Wine sees.
    public func windowsPath(_ url: URL) -> String {
        let driveC = bottle.appending(path: "drive_c").standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(driveC) {
            return "C:" + path.dropFirst(driveC.count).replacingOccurrences(of: "/", with: "\\")
        }
        return "Z:" + path.replacingOccurrences(of: "/", with: "\\")
    }
}
