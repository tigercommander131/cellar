import CryptoKit
import Foundation

public enum PackKind: String, Codable, Sendable, CaseIterable {
    case engine, dxmt, d3dmetal, profiles
}

/// One downloadable component. `packs.json` lists the current one of each kind.
public struct PackEntry: Codable, Sendable, Equatable {
    public var kind: PackKind
    public var version: String
    public var url: URL
    public var sha256: String
    /// Folder inside the archive that becomes the pack's root ("" = the archive's top level).
    public var archiveRoot: String
    /// When set, only these paths (relative to `archiveRoot`) are kept. Used for D3DMetal,
    /// which is cut out of Gcenx's Game Porting Toolkit build on the user's own Mac.
    public var keep: [String]?

    public init(kind: PackKind, version: String, url: URL, sha256: String, archiveRoot: String = "", keep: [String]? = nil) {
        self.kind = kind
        self.version = version
        self.url = url
        self.sha256 = sha256
        self.archiveRoot = archiveRoot
        self.keep = keep
    }
}

public struct PackManifest: Codable, Sendable {
    public var schema: Int
    public var packs: [PackEntry]

    public func entry(_ kind: PackKind) -> PackEntry? { packs.first { $0.kind == kind } }

    public static let remoteURL = URL(string: "https://github.com/tigercommander131/cellar/releases/download/packs/packs.json")!

    public static func load(from url: URL) async throws -> PackManifest {
        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            let (body, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CellarError("Couldn't fetch \(url.lastPathComponent).") }
            data = body
        }
        return try JSONDecoder().decode(PackManifest.self, from: data)
    }
}

/// What is installed for one kind, stored as `.cellar-pack` inside the pack folder.
public struct InstalledPack: Codable, Sendable, Equatable {
    public var kind: PackKind
    public var version: String
    public var sha256: String
}

public struct PackStore: Sendable {
    public let paths: CellarPaths
    public init(paths: CellarPaths) { self.paths = paths }

    static let marker = ".cellar-pack"

    public func installed(_ kind: PackKind) -> InstalledPack? {
        let url = paths.pack(kind).appending(path: Self.marker)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(InstalledPack.self, from: data)
    }

    public func isCurrent(_ entry: PackEntry) -> Bool {
        installed(entry.kind)?.sha256 == entry.sha256
    }

    /// Downloads (or reuses a cached download), verifies, unpacks to a staging folder,
    /// then swaps it in. The old pack stays until the new one is fully in place.
    public func install(_ entry: PackEntry, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try paths.ensureLayout()
        let archive = try await Downloader(directory: paths.downloads).fetch(entry.url, sha256: entry.sha256, progress: progress)
        try installArchive(archive, entry: entry)
    }

    public func installArchive(_ archive: URL, entry: PackEntry) throws {
        let fm = FileManager.default
        let staging = paths.packs.appending(path: "staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        var tarArgs = ["-xf", archive.path, "-C", staging.path]
        if let keep = entry.keep {
            let prefix = entry.archiveRoot.isEmpty ? "" : entry.archiveRoot + "/"
            tarArgs += keep.map { prefix + $0 }
        }
        try Shell.check("/usr/bin/tar", tarArgs)

        let root = entry.archiveRoot.isEmpty ? staging : staging.appending(path: entry.archiveRoot, directoryHint: .isDirectory)
        guard fm.fileExists(atPath: root.path) else { throw CellarError("\(entry.kind.rawValue) pack is missing \(entry.archiveRoot).") }
        _ = try? Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", root.path])

        let marker = InstalledPack(kind: entry.kind, version: entry.version, sha256: entry.sha256)
        try JSONEncoder().encode(marker).write(to: root.appending(path: Self.marker))

        let target = paths.pack(entry.kind)
        let old = paths.packs.appending(path: "old-\(entry.kind.rawValue)-\(UUID().uuidString)", directoryHint: .isDirectory)
        if fm.fileExists(atPath: target.path) { try fm.moveItem(at: target, to: old) }
        do {
            try fm.moveItem(at: root, to: target)
        } catch {
            if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: target) }
            throw error
        }
        try? fm.removeItem(at: old)
    }

    /// Leftovers from an install that crashed halfway.
    public func removeLeftovers() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: paths.packs, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent.hasPrefix("staging-") || item.lastPathComponent.hasPrefix("old-") {
            try? fm.removeItem(at: item)
        }
    }
}

/// Downloads into the shared cache with a `.partial` file, then checks SHA-256.
public struct Downloader: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func fetch(_ url: URL, sha256: String?, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        if url.isFileURL {
            if let sha256 { try Self.verify(url, sha256: sha256) }
            return url
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = sha256.map { String($0.prefix(12)) + "-" + url.lastPathComponent } ?? url.lastPathComponent
        let dest = directory.appending(path: name)
        if let sha256, FileManager.default.fileExists(atPath: dest.path), (try? Self.verify(dest, sha256: sha256)) != nil {
            return dest
        }
        let delegate = ProgressDelegate(progress: progress)
        let (temp, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CellarError("Download failed (\((response as? HTTPURLResponse)?.statusCode ?? 0)): \(url.absoluteString)")
        }
        let partial = dest.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        try FileManager.default.moveItem(at: temp, to: partial)
        if let sha256 { try Self.verify(partial, sha256: sha256) }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: partial, to: dest)
        return dest
    }

    public static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verify(_ url: URL, sha256: String) throws {
        let actual = try sha256Hex(of: url)
        guard actual == sha256.lowercased() else {
            throw CellarError("\(url.lastPathComponent) failed its checksum (got \(actual.prefix(12))…).")
        }
    }
}

private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let progress: (@Sendable (Double) -> Void)?
    init(progress: (@Sendable (Double) -> Void)?) { self.progress = progress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
