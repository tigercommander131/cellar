import Foundation

/// Where Cellar keeps everything on disk. One root per Mac user:
///
///     ~/Library/Application Support/Cellar/
///     ├── packs/{engine,dxmt,d3dmetal,profiles}/
///     ├── bottles/<name>/
///     ├── cache/{downloads,artwork,shaders}/
///     ├── logs/
///     └── state.json
public struct CellarPaths: Sendable, Equatable {
    public let root: URL

    public init(root: URL = CellarPaths.defaultRoot) {
        self.root = root
    }

    /// `CELLAR_HOME` overrides the location (used by tests and the CLI).
    public static var defaultRoot: URL {
        if let override = ProcessInfo.processInfo.environment["CELLAR_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Cellar", directoryHint: .isDirectory)
    }

    public var packs: URL { root.appending(path: "packs", directoryHint: .isDirectory) }
    public var bottles: URL { root.appending(path: "bottles", directoryHint: .isDirectory) }
    public var cache: URL { root.appending(path: "cache", directoryHint: .isDirectory) }
    public var downloads: URL { cache.appending(path: "downloads", directoryHint: .isDirectory) }
    public var artwork: URL { cache.appending(path: "artwork", directoryHint: .isDirectory) }
    public var shaders: URL { cache.appending(path: "shaders", directoryHint: .isDirectory) }
    public var logs: URL { root.appending(path: "logs", directoryHint: .isDirectory) }
    public var state: URL { root.appending(path: "state.json") }

    public func pack(_ kind: PackKind) -> URL {
        packs.appending(path: kind.rawValue, directoryHint: .isDirectory)
    }

    public func bottle(_ name: String) -> URL {
        bottles.appending(path: name, directoryHint: .isDirectory)
    }

    /// Creates the top-level folders if they are missing.
    public func ensureLayout() throws {
        for dir in [packs, bottles, downloads, artwork, shaders, logs] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
