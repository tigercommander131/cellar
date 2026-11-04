import Darwin
import Foundation

/// A game Steam knows about in the bottle, from its `appmanifest_<id>.acf`.
public struct SteamApp: Sendable, Equatable, Identifiable, Codable {
    public var id: String
    public var name: String
    public var installDir: String
    public var libraryPath: String
    public var stateFlags: Int
    public var sizeOnDisk: Int64
    public var bytesToDownload: Int64
    public var bytesDownloaded: Int64

    public var isInstalled: Bool { stateFlags & 4 != 0 }
    public var isUpdating: Bool { stateFlags & (2 | 1024) != 0 }
    public var downloadProgress: Double? {
        guard bytesToDownload > 0, bytesDownloaded < bytesToDownload else { return nil }
        return Double(bytesDownloaded) / Double(bytesToDownload)
    }

    /// Steam's own tools that show up as apps.
    public var isTool: Bool {
        ["228980"].contains(id) || name.hasPrefix("Steamworks Common") || name.hasPrefix("Proton")
    }
}

public struct Steam: Sendable {
    public let bottle: Bottle

    public init(bottle: Bottle) { self.bottle = bottle }

    public static let installerURL = URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!

    public var steamDir: URL { bottle.driveC.appending(path: "Program Files (x86)/Steam", directoryHint: .isDirectory) }
    public var steamExe: URL { steamDir.appending(path: "steam.exe") }
    public var isInstalled: Bool { FileManager.default.fileExists(atPath: steamExe.path) }
    public var windowsSteamExe: String { #"C:\Program Files (x86)\Steam\steam.exe"# }

    // MARK: Install

    public func install(engine: URL, log: URL) async throws {
        let paths = bottle.paths
        let setup = try await Downloader(directory: paths.downloads).fetch(Self.installerURL, sha256: nil)
        let dir = bottle.driveC.appending(path: "cellar", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let local = dir.appending(path: "SteamSetup.exe")
        try? FileManager.default.removeItem(at: local)
        try FileManager.default.copyItem(at: setup, to: local)
        let wine = bottle.wine(engine: engine)
        try wine.run([wine.windowsPath(local), "/S"], config: LaunchConfig(backend: .wined3d), log: log, timeout: 600)
        // The installer may start Steam by itself; stop it so we launch with our settings.
        wine.kill()
        guard isInstalled else { throw CellarError("The Steam installer finished but steam.exe is missing. See \(log.path).") }
    }

    // MARK: Launch

    public enum Mode: Sendable, Equatable {
        case open
        case silent
        case play(appID: String, args: [String])
        case install(appID: String)
        /// A steam:// link handed to the running Windows Steam (a Mac `open` would reach Mac Steam).
        case url(String)
        /// Joins a friend's game with a validated steam:// link, using that game's settings.
        case join(appID: String, link: String)
    }

    /// `-cef-disable-gpu` keeps Steam's Chromium UI on the CPU, which is what renders under Wine.
    public static func arguments(_ mode: Mode, steamArgs: [String] = [], hideSteam: Bool = false) -> [String] {
        let base = [#"C:\Program Files (x86)\Steam\steam.exe"#, "-cef-disable-gpu", "-cef-disable-gpu-compositing"] + steamArgs
        switch mode {
        case .open: return base
        case .silent: return base + ["-silent"]
        case .play(let id, let args): return base + (hideSteam ? ["-silent"] : []) + ["-applaunch", id] + args
        case .install(let id): return base + ["steam://install/\(id)"]
        case .url(let link): return base + [link]
        case .join(_, let link): return base + (hideSteam ? ["-silent"] : []) + [link]
        }
    }

    /// A crashed Chromium leaves a lock that makes the next start silently windowless.
    public func clearStaleLocks() {
        let fm = FileManager.default
        for dir in ["htmlcache", "config/htmlcache"] {
            let base = steamDir.appending(path: dir, directoryHint: .isDirectory)
            for name in ["SingletonLock", "SingletonCookie", "SingletonSocket", "lockfile"] {
                try? fm.removeItem(at: base.appending(path: name))
            }
        }
    }

    // MARK: Library

    public func libraryFolders() -> [URL] {
        var folders = [steamDir.appending(path: "steamapps", directoryHint: .isDirectory)]
        let vdfURL = steamDir.appending(path: "steamapps/libraryfolders.vdf")
        if let vdf = try? VDF.parse(contentsOf: vdfURL), let root = vdf["libraryfolders"] {
            for (_, entry) in root.pairs {
                guard let path = entry["path"]?.string else { continue }
                let mac = macPath(fromWindows: path).appending(path: "steamapps", directoryHint: .isDirectory)
                if !folders.contains(where: { $0.standardizedFileURL == mac.standardizedFileURL }) { folders.append(mac) }
            }
        }
        return folders
    }

    public func apps() -> [SteamApp] {
        let fm = FileManager.default
        var result: [SteamApp] = []
        for folder in libraryFolders() {
            guard let files = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            for file in files where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                guard let vdf = try? VDF.parse(contentsOf: folder.appending(path: file)),
                      let state = vdf["AppState"], let id = state["appid"]?.string else { continue }
                result.append(SteamApp(
                    id: id,
                    name: state["name"]?.string ?? "App \(id)",
                    installDir: state["installdir"]?.string ?? "",
                    libraryPath: folder.path,
                    stateFlags: Int(state["StateFlags"]?.string ?? "") ?? 0,
                    sizeOnDisk: Int64(state["SizeOnDisk"]?.string ?? "") ?? 0,
                    bytesToDownload: Int64(state["BytesToDownload"]?.string ?? "") ?? 0,
                    bytesDownloaded: Int64(state["BytesDownloaded"]?.string ?? "") ?? 0
                ))
            }
        }
        return result.filter { !$0.isTool }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Artwork Steam already has

    /// Art from Steam's own cache, which works with no network. nil for anything it hasn't saved.
    public func localArtwork(_ appID: String) -> SteamArtwork? {
        let folder = steamDir.appending(path: "appcache/librarycache/\(appID)", directoryHint: .isDirectory)
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        var art = SteamArtwork()
        for case let file as URL in walker {
            switch file.lastPathComponent.lowercased() {
            case "library_600x900.jpg", "library_capsule.jpg": art.capsule = file
            case "library_hero.jpg": art.hero = file
            case "library_header.jpg", "header.jpg": art.header = file
            case "logo.png": art.logo = file
            default: break
            }
        }
        return art == SteamArtwork() ? nil : art
    }

    // MARK: Offline mode

    var loginUsersURL: URL { steamDir.appending(path: "config/loginusers.vdf") }

    /// Steam's own "start offline" setting for the remembered account(s). Offline mode uses the
    /// sign-in saved from the last online start, so games launch on networks that block Steam.
    public var offlineMode: Bool {
        guard let vdf = try? VDF.parse(contentsOf: loginUsersURL), let users = vdf["users"] else { return false }
        let recent = users.pairs.first { $0.1["MostRecent"]?.string == "1" } ?? users.pairs.first
        return recent?.1["WantsOfflineMode"]?.string == "1"
    }

    /// Steam rewrites this file when it exits, so call this only while Steam is closed.
    public func setOfflineMode(_ offline: Bool) throws {
        guard let text = try? String(contentsOf: loginUsersURL, encoding: .utf8) else {
            throw CellarError("Sign in to Steam once while online before using offline mode.")
        }
        let value = offline ? "1" : "0"
        let keys = ["WantsOfflineMode", "SkipOfflineModeWarning"]
        var lines = text.components(separatedBy: "\n")
        // Set existing keys in place.
        var seen: Set<String> = []
        for i in lines.indices {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            for key in keys where trimmed.hasPrefix("\"\(key)\"") {
                let indent = lines[i].prefix { $0 == "\t" || $0 == " " }
                lines[i] = "\(indent)\"\(key)\"\t\t\"\(value)\""
                seen.insert(key)
            }
        }
        // Add missing keys before the closing brace of each account block ("<17-digit id>" { ... }).
        let missing = keys.filter { !seen.contains($0) }
        if !missing.isEmpty {
            var out: [String] = []
            var inAccount = false
            var pendingAccount = false
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.count == 19, trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.dropFirst().dropLast().allSatisfy(\.isNumber) {
                    pendingAccount = true
                } else if pendingAccount, trimmed == "{" {
                    inAccount = true
                    pendingAccount = false
                } else if inAccount, trimmed == "}" {
                    let indent = String(line.prefix { $0 == "\t" || $0 == " " })
                    for key in missing { out.append("\(indent)\t\"\(key)\"\t\t\"\(value)\"") }
                    inAccount = false
                }
                out.append(line)
            }
            lines = out
        }
        try lines.joined(separator: "\n").write(to: loginUsersURL, atomically: true, encoding: .utf8)
    }

    /// The signed-in account, if Steam remembers one.
    public func signedInUser() -> String? {
        guard let vdf = try? VDF.parse(contentsOf: steamDir.appending(path: "config/loginusers.vdf")),
              let users = vdf["users"] else { return nil }
        let recent = users.pairs.first { $0.1["MostRecent"]?.string == "1" } ?? users.pairs.first
        return recent?.1["PersonaName"]?.string ?? recent?.1["AccountName"]?.string
    }

    func macPath(fromWindows path: String) -> URL {
        let normal = path.replacingOccurrences(of: "\\\\", with: "\\")
        if normal.lowercased().hasPrefix("c:") {
            return bottle.driveC.appending(path: String(normal.dropFirst(2)).replacingOccurrences(of: "\\", with: "/"))
        }
        if normal.lowercased().hasPrefix("z:") {
            return URL(fileURLWithPath: String(normal.dropFirst(2)).replacingOccurrences(of: "\\", with: "/"))
        }
        return URL(fileURLWithPath: normal)
    }

    // MARK: Status from Steam's own logs

    /// True once Steam has finished starting up this session.
    public func isReady(since start: Date) -> Bool {
        let log = steamDir.appending(path: "logs/console_log.txt")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: log.path),
              let modified = attrs[.modificationDate] as? Date, modified >= start.addingTimeInterval(-2),
              let text = try? String(contentsOf: log, encoding: .utf8) else { return false }
        return text.suffix(200_000).contains("System startup time:")
    }

    /// Which apps have a program running from their install folder, given Windows paths of running
    /// programs. This reads real processes: Steam's own log goes stale after a crash and stays
    /// quiet in offline mode.
    public static func appIDs(_ apps: [SteamApp], runningFrom paths: [String]) -> Set<String> {
        let lowered = paths.map { $0.lowercased() }
        return Set(apps.filter { app in
            guard !app.installDir.isEmpty else { return false }
            let folder = "\\steamapps\\common\\\(app.installDir.lowercased())\\"
            return lowered.contains { $0.contains(folder) }
        }.map(\.id))
    }

    /// Some games insist on reading their own ID from this file (Nuclear Option hangs without it).
    public func writeSteamAppID(_ appID: String) {
        guard let app = apps().first(where: { $0.id == appID }), !app.installDir.isEmpty else { return }
        let file = URL(fileURLWithPath: app.libraryPath).appending(path: "common/\(app.installDir)/steam_appid.txt")
        if !FileManager.default.fileExists(atPath: file.path) {
            try? appID.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
