import Foundation

public enum GraphicsBackend: String, Codable, Sendable, CaseIterable {
    /// Apple's D3DMetal (Game Porting Toolkit): DirectX 11 and 12.
    case d3dmetal
    /// DXMT: DirectX 10 and 11 straight to Metal.
    case dxmt
    /// Wine's own OpenGL-based Direct3D. Slow, but works for old games.
    case wined3d

    public var displayName: String {
        switch self {
        case .d3dmetal: "D3DMetal (DX11/12)"
        case .dxmt: "DXMT (DX10/11)"
        case .wined3d: "WineD3D (compatibility)"
        }
    }
}

/// Wine looks for its built-in DLLs in the engine's own `lib/wine` before anywhere else,
/// so each graphics backend gets its own copy of the engine with that backend's DLLs
/// laid over it. The copies are APFS clones, so they cost almost no disk space.
public struct RuntimeBuilder: Sendable {
    public let paths: CellarPaths
    public init(paths: CellarPaths) { self.paths = paths }

    static let d3dmetalPE = ["dxgi", "d3d11", "d3d12", "d3d10", "atidxx64", "nvapi64", "nvngx"]
    static let dxmtPE = ["dxgi", "d3d11", "d3d10core", "winemetal"]

    public func runtimeRoot(_ backend: GraphicsBackend) -> URL {
        paths.packs.appending(path: "runtime-\(backend.rawValue)", directoryHint: .isDirectory)
    }

    /// The engine folder to run for `backend`, built or rebuilt if its inputs changed.
    public func prepare(_ backend: GraphicsBackend) throws -> URL {
        let store = PackStore(paths: paths)
        guard let engine = store.installed(.engine) else { throw CellarError("The Wine engine isn't installed yet.") }
        let overlay: InstalledPack?
        switch backend {
        case .wined3d: return paths.pack(.engine)
        case .dxmt: overlay = store.installed(.dxmt)
        case .d3dmetal: overlay = store.installed(.d3dmetal)
        }
        guard let overlay else { throw CellarError("\(backend.displayName) isn't installed yet.") }

        let root = runtimeRoot(backend)
        let stamp = "\(engine.sha256)+\(overlay.sha256)+v1"
        let stampURL = root.appending(path: ".cellar-runtime")
        if (try? String(contentsOf: stampURL, encoding: .utf8)) == stamp { return root }

        let fm = FileManager.default
        let staging = paths.packs.appending(path: "staging-runtime-\(backend.rawValue)", directoryHint: .isDirectory)
        try? fm.removeItem(at: staging)
        // -c clones on APFS: instant and free until a file changes.
        try Shell.check("/bin/cp", ["-cR", paths.pack(.engine).path, staging.path])

        let lib = staging.appending(path: "lib/wine", directoryHint: .isDirectory)
        switch backend {
        case .dxmt:
            let src = paths.pack(.dxmt)
            for name in Self.dxmtPE {
                try replace(lib.appending(path: "x86_64-windows/\(name).dll"), with: src.appending(path: "x86_64-windows/\(name).dll"))
            }
            try replace(lib.appending(path: "x86_64-unix/winemetal.so"), with: src.appending(path: "x86_64-unix/winemetal.so"))
        case .d3dmetal:
            let src = paths.pack(.d3dmetal)
            for name in Self.d3dmetalPE {
                try replace(lib.appending(path: "x86_64-windows/\(name).dll"), with: src.appending(path: "lib/wine/x86_64-windows/\(name).dll"))
                let so = lib.appending(path: "x86_64-unix/\(name).so")
                try? fm.removeItem(at: so)
                try fm.createSymbolicLink(at: so, withDestinationURL: src.appending(path: "lib/external/libd3dshared.dylib"))
            }
        case .wined3d:
            break
        }
        try stamp.write(to: staging.appending(path: ".cellar-runtime"), atomically: true, encoding: .utf8)
        try? fm.removeItem(at: root)
        try fm.moveItem(at: staging, to: root)
        return root
    }

    private func replace(_ target: URL, with source: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { throw CellarError("Missing \(source.lastPathComponent) in graphics pack.") }
        try? fm.removeItem(at: target)
        try fm.copyItem(at: source, to: target)
    }

    /// The D3DMetal library Wine's loader registers with Rosetta, when that backend is used.
    public func libd3dshared() -> URL {
        paths.pack(.d3dmetal).appending(path: "lib/external/libd3dshared.dylib")
    }
}
