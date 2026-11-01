import Foundation

/// Cellar's answer to "will this game run on this Mac?".
public enum CompatibilityVerdict: String, Codable, Sendable, Comparable {
    /// Someone proved it here: it ran for a good while on this Mac, or the player said so.
    case runsWell
    /// Nothing proven, but nothing against it, and there's at least one good sign.
    case shouldRun
    case mayStruggle
    /// Anti-cheat that doesn't work under Wine.
    case blocked
    /// Cellar has nothing to go on yet.
    case unknown

    public var title: String {
        switch self {
        case .runsWell: "Runs well"
        case .shouldRun: "Should run"
        case .mayStruggle: "May struggle"
        case .blocked: "Blocked"
        case .unknown: "Not checked"
        }
    }

    private var rank: Int {
        switch self {
        case .runsWell: 0
        case .shouldRun: 1
        case .unknown: 2
        case .mayStruggle: 3
        case .blocked: 4
        }
    }

    public static func < (a: CompatibilityVerdict, b: CompatibilityVerdict) -> Bool { a.rank < b.rank }
}

public struct CompatibilityReason: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case good, info, warning, bad }
    public var kind: Kind
    public var text: String
    public var id: String { text }

    public init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct CompatibilityAssessment: Codable, Sendable, Equatable {
    public var verdict: CompatibilityVerdict
    public var reasons: [CompatibilityReason]
}

/// Everything known about a game, from its files, public data and this Mac's history.
public struct CompatibilityFacts: Codable, Sendable, Equatable {
    /// Kernel anti-cheat found in the game's folder.
    public var antiCheatFiles: [String] = []
    /// From AreWeAntiCheatYet: Supported, Running, Planned, Broken or Denied (results on Linux).
    public var antiCheatStatus: String?
    public var antiCheats: [String] = []
    /// ProtonDB's rating: platinum, gold, silver, bronze or borked (results on Linux, so only a hint).
    public var protonTier: String?
    public var protonReports: Int?
    /// The store page's minimum memory, in GB.
    public var minimumMemoryGB: Int?
    public var hasMacVersion: Bool?
    /// Graphics libraries the game links to, lowercased: d3d11, d3d12, vulkan-1...
    public var graphicsAPIs: [String] = []
    public var is32Bit: Bool?
    public var playedSeconds: Double = 0
    /// Launches that closed within about 20 seconds, since the last long session.
    public var quickExits: Int = 0
    /// The player's own "works" or "doesn't work".
    public var report: Bool?

    public init() {}
}

public enum CompatibilityAssessor {
    /// Ten minutes in a game is well past any crash at startup.
    public static let provenSeconds: Double = 600

    /// `memoryGB` is this Mac's. Order matters only for how reasons are listed: worst first.
    public static func assess(_ facts: CompatibilityFacts, memoryGB: Int) -> CompatibilityAssessment {
        var bad: [CompatibilityReason] = []
        var warnings: [CompatibilityReason] = []
        var good: [CompatibilityReason] = []
        var info: [CompatibilityReason] = []

        let usesKernelAntiCheat = !facts.antiCheatFiles.isEmpty || kernelAntiCheats(facts.antiCheats)
        let names = (facts.antiCheatFiles.isEmpty ? kernelAntiCheatNames(facts.antiCheats) : facts.antiCheatFiles).joined(separator: ", ")
        if usesKernelAntiCheat {
            switch facts.antiCheatStatus {
            case "Supported", "Running":
                warnings.append(.init(.warning, "Uses \(names). It works on Linux, but that isn't proven on a Mac, so online play may be refused."))
            default:
                bad.append(.init(.bad, "Uses \(names), which doesn't work under Wine."))
            }
        } else if facts.antiCheatStatus == "Denied" || facts.antiCheatStatus == "Broken" {
            bad.append(.init(.bad, "Its anti-cheat is reported as not working under Wine."))
        }

        if let need = facts.minimumMemoryGB, need > memoryGB {
            warnings.append(.init(.warning, "Steam says it needs \(need) GB of memory. This Mac has \(memoryGB) GB."))
        } else if let need = facts.minimumMemoryGB, need >= memoryGB - 2, need > 4 {
            info.append(.init(.info, "Steam says it needs \(need) GB of memory, close to this Mac's \(memoryGB) GB. Close other apps first."))
        }

        if facts.graphicsAPIs.contains("vulkan-1"),
           !facts.graphicsAPIs.contains(where: { $0.hasPrefix("d3d") }) {
            warnings.append(.init(.warning, "It draws with Vulkan, which Cellar's graphics options don't handle well."))
        }
        if facts.is32Bit == true {
            warnings.append(.init(.warning, "It's a 32-bit game, so it can't use the fastest graphics options."))
        }
        if facts.quickExits >= 2 {
            warnings.append(.init(.warning, "It closed right after starting \(facts.quickExits) times on this Mac. Try another graphics option in its settings."))
        }
        switch facts.protonTier {
        case "platinum", "gold":
            good.append(.init(.good, "Rated \(facts.protonTier!) on ProtonDB. That's Linux, so it's a good sign rather than proof."))
        case "silver":
            info.append(.init(.info, "Rated silver on ProtonDB, so expect some problems. That's Linux, so it's only a hint."))
        case "bronze", "borked":
            warnings.append(.init(.warning, "Rated \(facts.protonTier!) on ProtonDB. That's Linux, so it's only a hint, but it's not a good one."))
        default:
            break
        }
        if facts.hasMacVersion == true {
            info.append(.init(.info, "Steam also sells a Mac version, which may run better than the Windows one."))
        }
        if facts.playedSeconds >= provenSeconds {
            good.insert(.init(.good, "Played for \(Self.duration(facts.playedSeconds)) on this Mac."), at: 0)
        } else if !usesKernelAntiCheat && bad.isEmpty && !facts.graphicsAPIs.isEmpty {
            good.append(.init(.good, "No anti-cheat in its files, and its graphics are supported."))
        }

        let verdict: CompatibilityVerdict
        var ownReport: [CompatibilityReason] = []
        if let report = facts.report {
            verdict = report ? .runsWell : .mayStruggle
            ownReport.append(.init(report ? .good : .warning, report ? "You said it works." : "You said it doesn't work."))
        } else if !bad.isEmpty && facts.playedSeconds < provenSeconds {
            verdict = .blocked
        } else if facts.playedSeconds >= provenSeconds {
            verdict = .runsWell
        } else if !warnings.isEmpty || !bad.isEmpty {
            verdict = .mayStruggle
        } else if !good.isEmpty {
            verdict = .shouldRun
        } else {
            verdict = .unknown
        }
        return CompatibilityAssessment(verdict: verdict, reasons: ownReport + bad + warnings + good + info)
    }

    static func kernelAntiCheats(_ names: [String]) -> Bool { !kernelAntiCheatNames(names).isEmpty }

    /// VAC and the like run fine under Wine; these don't.
    static func kernelAntiCheatNames(_ names: [String]) -> [String] {
        let harmless = ["vac", "valve anti-cheat", "steam custom", "custom"]
        return names.filter { !harmless.contains($0.lowercased()) }
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes < 60 ? "\(minutes) minutes" : "\(minutes / 60)h \(minutes % 60)m"
    }

    // MARK: Store page and game files

    /// Reads "Memory: 8 GB RAM" (or MB) out of the store's minimum requirements.
    public static func minimumMemoryGB(requirements html: String) -> Int? {
        let plain = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        guard let range = plain.range(of: #"(?i)memory\s*:\s*([0-9.]+)\s*(gb|mb)"#, options: .regularExpression) else { return nil }
        let match = plain[range].lowercased()
        guard let number = match.range(of: #"[0-9.]+"#, options: .regularExpression).flatMap({ Double(match[$0]) }) else { return nil }
        return match.hasSuffix("mb") ? Int((number / 1024).rounded(.up)) : Int(number.rounded(.up))
    }

    /// Files that show kernel anti-cheat, lowercased name fragment to display name.
    static let antiCheatMarkers: [(String, String)] = [
        ("easyanticheat", "Easy Anti-Cheat"), ("start_protected_game", "Easy Anti-Cheat"),
        ("battleye", "BattlEye"), ("beservice", "BattlEye"), ("beclient", "BattlEye"),
        ("vgk.sys", "Riot Vanguard"), ("vanguard", "Riot Vanguard"),
        ("xigncode", "XIGNCODE3"), ("gameguard", "nProtect GameGuard"), ("npggnt", "nProtect GameGuard"),
        ("pnkbstr", "PunkBuster"), ("punkbuster", "PunkBuster"), ("mhyprot", "miHoYo Protect"),
        ("anticheatexpert", "Anti-Cheat Expert"), ("ace-base", "Anti-Cheat Expert"), ("equ8", "EQU8"),
        ("xhunter1", "Wellbia"), ("eaanticheat", "EA anticheat"), ("faceit", "FACEIT"),
    ]

    public struct GameFiles: Sendable, Equatable {
        public var antiCheat: [String] = []
        public var graphicsAPIs: [String] = []
        public var is32Bit: Bool?
    }

    /// Looks through a game's folder without reading whole files: names for anti-cheat, and the
    /// import table of its main program for the graphics it links to.
    public static func scan(folder: URL) -> GameFiles {
        var result = GameFiles()
        var found: Set<String> = []
        var programs: [(url: URL, size: Int)] = []
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else { return result }
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited > 40_000 { break }
            if walker.level > 4 { walker.skipDescendants(); continue }
            let name = url.lastPathComponent.lowercased()
            for (marker, display) in antiCheatMarkers where name.contains(marker) { found.insert(display) }
            guard name.hasSuffix(".exe") || name == "unityplayer.dll" else { continue }
            // Installers, redistributables and crash reporters don't say what the game draws with.
            let skip = ["crash", "unins", "redist", "vcredist", "dxsetup", "setup", "installer", "dotnet", "ue4prereq", "uecrash", "easyanticheat"]
            if skip.contains(where: name.contains) { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            programs.append((url, name == "unityplayer.dll" ? Int.max : size))
        }
        result.antiCheat = found.sorted()
        let biggest = programs.sorted { $0.size > $1.size }.prefix(4)
        var anyBits64 = false
        var anyBits32 = false
        var apis: Set<String> = []
        for program in biggest {
            guard let pe = PEFile(url: program.url) else { continue }
            if pe.is64Bit { anyBits64 = true } else { anyBits32 = true }
            apis.formUnion(pe.imports.compactMap { graphicsLibrary($0) })
        }
        result.graphicsAPIs = apis.sorted()
        if anyBits64 || anyBits32 { result.is32Bit = !anyBits64 }
        return result
    }

    static func graphicsLibrary(_ dll: String) -> String? {
        let name = dll.lowercased().replacingOccurrences(of: ".dll", with: "")
        return ["d3d9", "d3d10", "d3d10core", "d3d11", "d3d12", "dxgi", "opengl32", "vulkan-1"].contains(name) ? name : nil
    }
}

/// The small part of a Windows program's header needed here: its bitness and the DLLs it links to.
struct PEFile {
    var is64Bit: Bool
    var imports: [String]

    init?(url: URL) {
        // Import tables can sit anywhere, but mapping the file costs nothing until it's touched.
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        self.init(data: data)
    }

    init?(data: Data) {
        func u16(_ at: Int) -> Int? {
            guard at >= 0, at + 2 <= data.count else { return nil }
            return Int(data[data.startIndex + at]) | Int(data[data.startIndex + at + 1]) << 8
        }
        func u32(_ at: Int) -> Int? {
            guard let low = u16(at), let high = u16(at + 2) else { return nil }
            return low | high << 16
        }
        guard u16(0) == 0x5A4D, let pe = u32(0x3C), u32(pe) == 0x0000_4550,
              let sections = u16(pe + 6), let optionalSize = u16(pe + 20), let magic = u16(pe + 24) else { return nil }
        is64Bit = magic == 0x20B
        imports = []
        let directories = pe + 24 + (is64Bit ? 112 : 96)
        guard let importRVA = u32(directories + 8), importRVA != 0 else { return }

        var table: [(rva: Int, size: Int, raw: Int)] = []
        let first = pe + 24 + optionalSize
        for index in 0..<min(sections, 96) {
            let entry = first + index * 40
            guard let virtualSize = u32(entry + 8), let rva = u32(entry + 12),
                  let rawSize = u32(entry + 16), let raw = u32(entry + 20) else { return }
            table.append((rva, max(virtualSize, rawSize), raw))
        }
        func offset(_ rva: Int) -> Int? {
            table.first { rva >= $0.rva && rva < $0.rva + $0.size }.map { rva - $0.rva + $0.raw }
        }
        guard var descriptor = offset(importRVA) else { return }
        for _ in 0..<512 {
            guard let nameRVA = u32(descriptor + 12), nameRVA != 0, let at = offset(nameRVA) else { break }
            var bytes: [UInt8] = []
            var cursor = at
            while cursor < data.count, bytes.count < 128 {
                let byte = data[data.startIndex + cursor]
                if byte == 0 { break }
                bytes.append(byte)
                cursor += 1
            }
            imports.append(String(decoding: bytes, as: UTF8.self))
            descriptor += 20
        }
    }
}

/// Gathers facts about a game and remembers them, so a check only touches the network now and then.
public actor CompatibilityService {
    public struct StoreMatch: Sendable, Identifiable, Equatable {
        public var id: String
        public var name: String
        public var image: URL?
    }

    struct Online: Codable {
        var antiCheatStatus: String?
        var antiCheats: [String] = []
        var protonTier: String?
        var protonReports: Int?
        var minimumMemoryGB: Int?
        var hasMacVersion: Bool?
        var checked: Date
    }

    struct Cache: Codable {
        var online: [String: Online] = [:]
        /// Keyed by install folder and size, so an update to the game means a new look.
        var files: [String: Files] = [:]
    }

    struct Files: Codable {
        var signature: String
        var antiCheat: [String]
        var graphicsAPIs: [String]
        var is32Bit: Bool?
    }

    private struct AntiCheatEntry: Decodable {
        struct Stores: Decodable { var steam: String? }
        var name: String
        var status: String?
        var anticheats: [String]?
        var storeIds: Stores?
    }

    static let antiCheatList = URL(string: "https://raw.githubusercontent.com/Starz0r/AreWeAntiCheatYet/HEAD/games.json")!
    static let onlineFreshness: TimeInterval = 14 * 86_400
    static let antiCheatFreshness: TimeInterval = 7 * 86_400

    let directory: URL
    var cache = Cache()
    var loaded = false
    private var antiCheatByID: [String: AntiCheatEntry] = [:]
    private var antiCheatByName: [String: AntiCheatEntry] = [:]
    var antiCheatLoaded = false

    public init(paths: CellarPaths) {
        directory = paths.cache.appending(path: "compatibility", directoryHint: .isDirectory)
    }

    /// Facts for a game: from its folder if it's installed, plus public data when the network allows.
    public func facts(appID: String, name: String, installFolder: URL?, size: Int64) async -> CompatibilityFacts {
        loadIfNeeded()
        var facts = CompatibilityFacts()
        if let installFolder {
            let signature = "\(installFolder.lastPathComponent)-\(size)"
            var files = cache.files[appID]
            if files?.signature != signature {
                let scanned = await Task.detached(priority: .utility) { CompatibilityAssessor.scan(folder: installFolder) }.value
                files = Files(signature: signature, antiCheat: scanned.antiCheat, graphicsAPIs: scanned.graphicsAPIs, is32Bit: scanned.is32Bit)
                cache.files[appID] = files
                save()
            }
            facts.antiCheatFiles = files?.antiCheat ?? []
            facts.graphicsAPIs = files?.graphicsAPIs ?? []
            facts.is32Bit = files?.is32Bit
        }
        if let online = await online(appID: appID, name: name) {
            facts.antiCheatStatus = online.antiCheatStatus
            facts.antiCheats = online.antiCheats
            facts.protonTier = online.protonTier
            facts.protonReports = online.protonReports
            facts.minimumMemoryGB = online.minimumMemoryGB
            facts.hasMacVersion = online.hasMacVersion
        }
        return facts
    }

    /// Steam's store search, for games that aren't installed.
    public func search(_ term: String) async -> [StoreMatch] {
        var components = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
        components.queryItems = [.init(name: "term", value: term), .init(name: "cc", value: "US"), .init(name: "l", value: "en")]
        struct Response: Decodable {
            struct Item: Decodable {
                var id: Int
                var name: String
                var type: String?
                var tiny_image: String?
            }
            var items: [Item]?
        }
        guard let url = components.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        let apps = (decoded.items ?? []).filter { $0.type == "app" || $0.type == nil }
        // The search also returns soundtracks and DLC, which only the store's item data tells apart.
        let games = await gameIDs(among: apps.map(\.id))
        return apps.filter { games?.contains($0.id) ?? true }.prefix(8).map {
            StoreMatch(id: String($0.id), name: $0.name, image: $0.tiny_image.flatMap(URL.init(string:)))
        }
    }

    /// nil when the store didn't answer, so a search still shows something.
    private func gameIDs(among ids: [Int]) async -> Set<Int>? {
        guard !ids.isEmpty else { return [] }
        let request: [String: Any] = ["ids": ids.map { ["appid": $0] },
                                      "context": ["language": "english", "country_code": "US"],
                                      "data_request": [String: Any]()]
        guard let body = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        var components = URLComponents(string: "https://api.steampowered.com/IStoreBrowseService/GetItems/v1/")!
        components.queryItems = [.init(name: "input_json", value: String(decoding: body, as: UTF8.self))]
        struct Response: Decodable {
            struct Body: Decodable { var store_items: [Item]? }
            struct Item: Decodable {
                var appid: Int?
                var type: Int?
            }
            var response: Body
        }
        guard let url = components.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return Set((decoded.response.store_items ?? []).filter { $0.type == 0 }.compactMap(\.appid))
    }

    private func online(appID: String, name: String) async -> Online? {
        if let cached = cache.online[appID], Date().timeIntervalSince(cached.checked) < Self.onlineFreshness { return cached }
        await loadAntiCheatList()
        var result = Online(checked: Date())
        var anyAnswer = false
        if let entry = antiCheatByID[appID] ?? antiCheatByName[Self.normalized(name)] {
            result.antiCheatStatus = entry.status
            result.antiCheats = entry.anticheats ?? []
        }
        if !antiCheatByID.isEmpty { anyAnswer = true }
        if let store = await storeDetails(appID) {
            anyAnswer = true
            result.minimumMemoryGB = store.memory
            result.hasMacVersion = store.mac
        }
        if let proton = await protonSummary(appID) {
            anyAnswer = true
            result.protonTier = proton.tier
            result.protonReports = proton.total
        }
        // Nothing answered (a blocked network): use what's saved, and ask again next time.
        guard anyAnswer else { return cache.online[appID] }
        cache.online[appID] = result
        save()
        return result
    }

    private func storeDetails(_ appID: String) async -> (memory: Int?, mac: Bool?)? {
        guard let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&filters=platforms,pc_requirements"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[appID] as? [String: Any] else { return nil }
        // Success false just means the store has no page for this app.
        let body = entry["data"] as? [String: Any]
        let requirements = (body?["pc_requirements"] as? [String: Any])?["minimum"] as? String
        return (requirements.flatMap(CompatibilityAssessor.minimumMemoryGB(requirements:)),
                (body?["platforms"] as? [String: Any])?["mac"] as? Bool)
    }

    private func protonSummary(_ appID: String) async -> (tier: String?, total: Int?)? {
        guard let url = URL(string: "https://www.protondb.com/api/v1/reports/summaries/\(appID).json"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (root["tier"] as? String, root["total"] as? Int)
    }

    private func loadAntiCheatList() async {
        guard !antiCheatLoaded else { return }
        let file = directory.appending(path: "anticheat.json")
        let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) }
        var data = try? Data(contentsOf: file)
        if data == nil || (age ?? .infinity) > Self.antiCheatFreshness,
           let (fresh, response) = try? await URLSession.shared.data(from: Self.antiCheatList),
           (response as? HTTPURLResponse)?.statusCode == 200 {
            data = fresh
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? fresh.write(to: file, options: .atomic)
        }
        guard let data, let entries = try? JSONDecoder().decode([AntiCheatEntry].self, from: data) else { return }
        antiCheatLoaded = true
        for entry in entries {
            if let id = entry.storeIds?.steam { antiCheatByID[id] = entry }
            antiCheatByName[Self.normalized(entry.name)] = entry
        }
    }

    static func normalized(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: directory.appending(path: "index.json")),
           let saved = try? decoder.decode(Cache.self, from: data) {
            cache = saved
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? encoder.encode(cache).write(to: directory.appending(path: "index.json"), options: .atomic)
    }
}
