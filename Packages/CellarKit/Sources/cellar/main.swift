import CellarKit
import Foundation

// `cellar` — the headless front door to CellarKit. Everything the app does, from a terminal.

let usage = """
usage: cellar <command> [options]

  status                         Mac checks, installed packs, Steam state
  setup [--manifest <url|path>]  Install engine, graphics, bottle and Steam
  pack install <kind> <archive> [--root <dir>] [--version <v>] [--keep a,b]
                                 Install a local pack archive (engine|dxmt|d3dmetal|profiles)
  bottle                         Create or update the Steam bottle
  steam-install                  Install Windows Steam into the bottle
  wine [--backend <b>] <args...> Run a raw Wine command in the Steam bottle (e.g. winecfg)
  run [--backend <b>] [--wait] <exe> [args...]
                                 Run a Windows program in the Steam bottle
  steam open | list | stop
  steam play <appid> [args...]   Launch a game through Steam with its profile
  steam install <appid>          Ask Steam to install a game
  processes                      List running Windows programs
  stop                           Force-quit everything Cellar started

Backends: d3dmetal, dxmt, wined3d. CELLAR_HOME overrides the data folder.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func takeOption(_ name: String, from args: inout [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...i + 1)
    return value
}

func takeFlag(_ name: String, from args: inout [String]) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

func backend(from args: inout [String]) -> GraphicsBackend {
    guard let raw = takeOption("--backend", from: &args) else { return .d3dmetal }
    guard let b = GraphicsBackend(rawValue: raw) else { fail("Unknown backend \(raw).") }
    return b
}

let core = CellarCore()
var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

do {
    switch command {
    case "status":
        let host = HostCheck.current(volume: core.paths.root)
        print("Data folder: \(core.paths.root.path)")
        print("Mac: \(host.memoryGB) GB RAM, macOS \(host.macOSVersion.majorVersion).\(host.macOSVersion.minorVersion), Rosetta \(host.rosettaInstalled ? "installed" : "missing"), \(host.availableDiskBytes / 1_000_000_000) GB free")
        print("Low-memory mode: \(core.lowMemoryMode(host: host) ? "on" : "off")")
        for problem in host.problems { print("  ! \(problem)") }
        for kind in PackKind.allCases {
            let p = core.packs.installed(kind)
            print("Pack \(kind.rawValue): \(p.map { "\($0.version) (\($0.sha256.prefix(12)))" } ?? "not installed")")
        }
        print("Steam bottle: \(core.steamBottle.exists ? "ready" : "missing"); Steam: \(core.steam.isInstalled ? "installed" : "not installed")\(core.isSteamRunning() ? ", running" : "")")
        if let user = core.steam.signedInUser() { print("Steam account: \(user)") }

    case "setup":
        let manifestURL: URL = {
            guard let raw = takeOption("--manifest", from: &args) else { return PackManifest.remoteURL }
            return raw.hasPrefix("http") ? URL(string: raw)! : URL(fileURLWithPath: raw)
        }()
        let manifest = try await PackManifest.load(from: manifestURL)
        let lastLine = LastLine()
        try await core.setup(manifest: manifest, step: { print("== \($0.rawValue)") }, progress: { text, fraction in
            lastLine.show(text, fraction)
        })
        print("\nSetup complete.")

    case "pack":
        guard args.first == "install", args.count >= 3, let kind = PackKind(rawValue: args[1]) else { fail(usage) }
        let archive = URL(fileURLWithPath: args[2])
        var rest = Array(args.dropFirst(3))
        let root = takeOption("--root", from: &rest) ?? ""
        let version = takeOption("--version", from: &rest) ?? "local"
        let keep = takeOption("--keep", from: &rest)?.split(separator: ",").map(String.init)
        let sha = try Downloader.sha256Hex(of: archive)
        try core.paths.ensureLayout()
        try core.packs.installArchive(archive, entry: PackEntry(kind: kind, version: version, url: archive, sha256: sha, archiveRoot: root, keep: keep))
        print("Installed \(kind.rawValue) \(version) (\(sha.prefix(12)))")

    case "bottle":
        let engine = try core.runtimes.prepare(.wined3d)
        let log = core.log("bottle")
        try core.steamBottle.create(engine: engine, log: log)
        print("Bottle ready: \(core.steamBottle.url.path)")

    case "steam-install":
        let engine = try core.runtimes.prepare(.wined3d)
        try await core.steam.install(engine: engine, log: core.log("steam-install"))
        print("Steam installed.")

    case "wine":
        let b = backend(from: &args)
        let engine = try core.runtimes.prepare(b)
        try core.steamBottle.prepare(for: b)
        let status = try core.steamBottle.wine(engine: engine).run(args, config: LaunchConfig(backend: b), log: core.log("wine"), timeout: 24 * 3600)
        exit(status)

    case "run":
        let b = backend(from: &args)
        let wait = takeFlag("--wait", from: &args)
        guard let exe = args.first else { fail(usage) }
        let status = try core.run(exe: URL(fileURLWithPath: exe), args: Array(args.dropFirst()), backend: b, wait: wait)
        if let status { exit(status) }

    case "steam":
        guard let sub = args.first else { fail(usage) }
        switch sub {
        case "open": try core.launchSteam(.open)
        case "stop": core.stopSteam()
        case "play":
            guard args.count >= 2 else { fail(usage) }
            try core.launchSteam(.play(appID: args[1], args: Array(args.dropFirst(2))))
        case "install":
            guard args.count >= 2 else { fail(usage) }
            try core.launchSteam(.install(appID: args[1]))
        case "list":
            for app in core.steam.apps() {
                let state = app.isInstalled ? "installed" : (app.downloadProgress.map { "downloading \(Int($0 * 100))%" } ?? "not installed")
                print("\(app.id)\t\(app.name)\t\(state)\t\(core.profiles.profile(for: app.id).backend.rawValue)")
            }
        default: fail(usage)
        }

    case "processes":
        for p in core.runningProcesses() { print("\(p.pid)\t\(p.windowsName)") }

    case "stop":
        core.stopEverything()

    default:
        print(usage)
        exit(2)
    }
} catch {
    fail("cellar: \(error.localizedDescription)")
}

/// Rewrites one terminal line with progress.
final class LastLine: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ""
    func show(_ text: String, _ fraction: Double?) {
        lock.lock(); defer { lock.unlock() }
        let line = fraction.map { "\(text) \(Int($0 * 100))%" } ?? text
        guard line != last else { return }
        last = line
        FileHandle.standardOutput.write(Data(("\r\u{1B}[K" + line).utf8))
        if fraction == nil { FileHandle.standardOutput.write(Data("\n".utf8)) }
    }
}
