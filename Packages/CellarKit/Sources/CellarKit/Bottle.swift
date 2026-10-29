import Foundation

/// Settings saved next to a bottle's fake C: drive.
public struct BottleInfo: Codable, Sendable, Equatable {
    public var name: String
    public var windowsVersion: String = "win10"
    public var created: Date = Date()
    public var engineSHA: String?
    public var setupVersion: Int = 0

    public init(name: String) { self.name = name }
}

/// One registry value, written through a REGEDIT5 file so many values cost one Wine start.
public struct RegistryValue: Codable, Sendable, Equatable {
    public enum Value: Codable, Sendable, Equatable {
        case string(String)
        case dword(UInt32)
        case delete
    }
    public var key: String
    public var name: String
    public var value: Value

    public init(key: String, name: String, value: Value) {
        self.key = key
        self.name = name
        self.value = value
    }

    /// Per-program DLL override, e.g. `dll("steam.exe", "d3d11", "builtin")`.
    public static func dll(_ exe: String, _ dll: String, _ mode: String) -> RegistryValue {
        RegistryValue(key: #"HKEY_CURRENT_USER\Software\Wine\AppDefaults\"# + exe + #"\DllOverrides"#, name: dll, value: .string(mode))
    }

    public static func retina(_ on: Bool) -> RegistryValue {
        RegistryValue(key: #"HKEY_CURRENT_USER\Software\Wine\Mac Driver"#, name: "RetinaMode", value: .string(on ? "y" : "n"))
    }
}

public enum RegistryFile {
    /// REGEDIT5 text, which regedit expects as UTF-16LE with a byte-order mark.
    public static func render(_ values: [RegistryValue]) -> Data {
        var text = "Windows Registry Editor Version 5.00\r\n"
        let grouped = Dictionary(grouping: values, by: \.key)
        for key in grouped.keys.sorted() {
            text += "\r\n[\(key)]\r\n"
            for value in grouped[key]! {
                let name = value.name.isEmpty ? "@" : "\"\(escape(value.name))\""
                switch value.value {
                case .string(let s): text += "\(name)=\"\(escape(s))\"\r\n"
                case .dword(let d): text += "\(name)=dword:\(String(format: "%08x", d))\r\n"
                case .delete: text += "\(name)=-\r\n"
                }
            }
        }
        var data = Data([0xFF, 0xFE])
        data.append(text.data(using: .utf16LittleEndian)!)
        return data
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

public struct Bottle: Sendable {
    public let paths: CellarPaths
    public let name: String

    public init(paths: CellarPaths, name: String) {
        self.paths = paths
        self.name = name
    }

    public var url: URL { paths.bottle(name) }
    public var driveC: URL { url.appending(path: "drive_c", directoryHint: .isDirectory) }
    var infoURL: URL { url.appending(path: "cellar-bottle.json") }
    public var exists: Bool { FileManager.default.fileExists(atPath: url.appending(path: "system.reg").path) }

    /// Bump when setup gains a step, so existing bottles get it on next launch.
    static let setupVersion = 1

    public var info: BottleInfo? {
        guard let data = try? Data(contentsOf: infoURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BottleInfo.self, from: data)
    }

    func save(_ info: BottleInfo) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(info).write(to: infoURL, options: .atomic)
    }

    public func wine(engine: URL) -> Wine { Wine(paths: paths, engine: engine, bottle: url) }

    /// Creates the Wine prefix, or brings an existing one up to the current setup version.
    public func create(engine: URL, log: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        let wine = wine(engine: engine)
        let config = LaunchConfig(backend: .wined3d)
        var info = self.info ?? BottleInfo(name: name)

        if !exists {
            try wine.run(["wineboot", "--init"], config: config, log: log, timeout: 300)
            // wineboot can return before the registry is flushed to disk.
            let deadline = Date().addingTimeInterval(60)
            while !exists, Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
            guard exists else { throw CellarError("Wine didn't finish creating the bottle. See \(log.path).") }
        }
        if info.setupVersion < Self.setupVersion {
            try wine.run(["winecfg", "-v", info.windowsVersion], config: config, log: log, timeout: 120)
            try replaceHomeLinks()
            try importRegistry(defaultRegistry(), engine: engine, log: log)
            info.setupVersion = Self.setupVersion
        }
        info.engineSHA = PackStore(paths: paths).installed(.engine)?.sha256
        wine.waitForServer()
        try save(info)
    }

    /// Wine links Documents, Desktop etc. to the real Mac folders. Games write junk there,
    /// so make them plain folders inside the bottle instead.
    func replaceHomeLinks() throws {
        let fm = FileManager.default
        let users = driveC.appending(path: "users", directoryHint: .isDirectory)
        guard let people = try? fm.contentsOfDirectory(at: users, includingPropertiesForKeys: nil) else { return }
        for person in people {
            guard let items = try? fm.contentsOfDirectory(at: person, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { continue }
            for item in items where (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                try fm.removeItem(at: item)
                try fm.createDirectory(at: item, withIntermediateDirectories: true)
            }
        }
    }

    func defaultRegistry() -> [RegistryValue] {
        [
            RegistryValue.retina(false),
            // Steam's client stalls on start probing audio devices (Wine 11.0 winmm); games keep sound.
            .dll("steam.exe", "winecoreaudio.drv", "disabled"),
            // WPAD proxy auto-detection stalls installers and launchers.
            RegistryValue(key: #"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings"#,
                          name: "AutoDetect", value: .dword(0)),
        ]
    }

    public func importRegistry(_ values: [RegistryValue], engine: URL, log: URL) throws {
        guard !values.isEmpty else { return }
        let dir = driveC.appending(path: "cellar", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "import-\(UUID().uuidString.prefix(8)).reg")
        try RegistryFile.render(values).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let wine = wine(engine: engine)
        try wine.run(["regedit", "/S", wine.windowsPath(file)], config: LaunchConfig(backend: .wined3d), log: log, timeout: 120)
    }

    /// DXMT's DLLs are found by name, so `winemetal.dll` must also exist in system32.
    public func prepare(for backend: GraphicsBackend) throws {
        guard backend == .dxmt else { return }
        let source = paths.pack(.dxmt).appending(path: "x86_64-windows/winemetal.dll")
        let target = driveC.appending(path: "windows/system32/winemetal.dll")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: source, to: target)
    }
}
