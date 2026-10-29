import Foundation

/// Per-game settings, keyed by Steam app ID. Built-in ones ship in the profiles pack;
/// a user's local overrides sit in `profiles/overrides/<appId>.json` and win field by field.
public struct GameProfile: Codable, Sendable, Equatable {
    public var appId: String
    public var title: String?
    public var graphics: GraphicsBackend?
    public var windowsVersion: String?
    public var minRAMGB: Int?
    public var env: [String: String]?
    public var dllOverrides: [String: String]?
    public var steamArgs: [String]?
    public var gameArgs: [String]?
    public var registry: [RegistryValue]?
    public var retina: Bool?
    /// Apple's Metal performance overlay (FPS, frame time, GPU) in the game.
    public var metalHUD: Bool?
    public var notes: String?

    public init(appId: String) { self.appId = appId }

    /// The settings a game gets when nobody has tuned it.
    public static func defaults(appId: String) -> GameProfile {
        var p = GameProfile(appId: appId)
        p.graphics = .d3dmetal
        p.windowsVersion = "win10"
        return p
    }

    /// Fields set in `other` replace ours.
    public func merged(with other: GameProfile?) -> GameProfile {
        guard let other else { return self }
        var p = self
        if let v = other.title { p.title = v }
        if let v = other.graphics { p.graphics = v }
        if let v = other.windowsVersion { p.windowsVersion = v }
        if let v = other.minRAMGB { p.minRAMGB = v }
        if let v = other.env { p.env = (p.env ?? [:]).merging(v) { $1 } }
        if let v = other.dllOverrides { p.dllOverrides = (p.dllOverrides ?? [:]).merging(v) { $1 } }
        if let v = other.steamArgs { p.steamArgs = v }
        if let v = other.gameArgs { p.gameArgs = v }
        if let v = other.registry { p.registry = (p.registry ?? []) + v }
        if let v = other.retina { p.retina = v }
        if let v = other.metalHUD { p.metalHUD = v }
        if let v = other.notes { p.notes = v }
        return p
    }

    public var backend: GraphicsBackend { graphics ?? .d3dmetal }
}

public struct ProfileStore: Sendable {
    public let paths: CellarPaths
    public init(paths: CellarPaths) { self.paths = paths }

    var builtInDir: URL { paths.pack(.profiles).appending(path: "profiles", directoryHint: .isDirectory) }
    var overridesDir: URL { paths.root.appending(path: "profiles/overrides", directoryHint: .isDirectory) }

    public func builtIn(_ appId: String) -> GameProfile? {
        load(builtInDir.appending(path: "\(appId).json"))
    }

    public func override(_ appId: String) -> GameProfile? {
        load(overridesDir.appending(path: "\(appId).json"))
    }

    /// Defaults, then the curated profile, then this Mac's overrides.
    public func profile(for appId: String) -> GameProfile {
        GameProfile.defaults(appId: appId).merged(with: builtIn(appId)).merged(with: override(appId))
    }

    public func saveOverride(_ profile: GameProfile) throws {
        try FileManager.default.createDirectory(at: overridesDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profile).write(to: overridesDir.appending(path: "\(profile.appId).json"), options: .atomic)
    }

    public func clearOverride(_ appId: String) {
        try? FileManager.default.removeItem(at: overridesDir.appending(path: "\(appId).json"))
    }

    func load(_ url: URL) -> GameProfile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GameProfile.self, from: data)
    }
}
