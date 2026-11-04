import Foundation
import IOKit

/// How much graphics a Mac can be expected to handle. Only a starting point, because Cellar can't
/// measure a game before it's played.
public enum MacTier: String, Codable, Sendable {
    /// Base chips without a fan, or 8 GB of memory.
    case entry
    /// Base chips with a fan, and Pro chips.
    case mid
    /// Max and Ultra chips.
    case high
}

public struct MacSpecs: Sendable, Equatable {
    public var chip: String
    public var modelName: String
    public var gpuCores: Int
    public var memoryGB: Int

    public init(chip: String, modelName: String, gpuCores: Int, memoryGB: Int) {
        self.chip = chip
        self.modelName = modelName
        self.gpuCores = gpuCores
        self.memoryGB = memoryGB
    }

    public var hasFan: Bool { !modelName.localizedCaseInsensitiveContains("Air") }

    public var tier: MacTier {
        if chip.contains("Max") || chip.contains("Ultra") { return memoryGB <= 8 ? .mid : .high }
        if memoryGB <= 8 { return .entry }
        if chip.contains("Pro") { return .mid }
        return hasFan ? .mid : .entry
    }

    public var summary: String {
        let cores = gpuCores > 0 ? ", \(gpuCores)-core GPU" : ""
        return "\(modelName), \(chip.replacingOccurrences(of: "Apple ", with: ""))\(cores), \(memoryGB) GB"
    }

    /// Runs `system_profiler`, so call it off the main thread, and only once.
    public static func current() -> MacSpecs {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0)
        var model = "Mac"
        if let result = try? Shell.run("/usr/sbin/system_profiler", ["SPHardwareDataType"]),
           let line = result.output.split(separator: "\n").first(where: { $0.contains("Model Name:") }) {
            model = line.replacingOccurrences(of: "Model Name:", with: "").trimmingCharacters(in: .whitespaces)
        }
        var cores = 0
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        if service != 0 {
            cores = (IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int) ?? 0
            IOObjectRelease(service)
        }
        return MacSpecs(chip: String(cString: bytes), modelName: model, gpuCores: cores,
                        memoryGB: Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()))
    }
}

/// Settings looked up by hand for one game, using the names in its own menus.
public struct CuratedGameSettings: Codable, Sendable, Equatable {
    public struct Row: Codable, Sendable, Equatable {
        public var name: String
        public var entry: String
        public var mid: String
        public var high: String
        public var why: String
    }

    public struct ByTier: Codable, Sendable, Equatable {
        public var entry: String
        public var mid: String
        public var high: String

        func value(_ tier: MacTier) -> String {
            switch tier {
            case .entry: entry
            case .mid: mid
            case .high: high
            }
        }
    }

    public var cellarPreset: ByTier
    public var target: ByTier
    public var note: String?
    public var settings: [Row]
}

public struct SettingsAdvice: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// Researched for this game by hand.
        case curated
        /// General guidance, using what PCGamingWiki says the game offers.
        case wiki(page: String)
        /// General guidance, with no knowledge of this game's options.
        case general
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public var name: String
        public var value: String
        public var why: String
        public var id: String { name }
    }

    public var target: String
    public var note: String?
    public var rows: [Row]
    public var preset: GamePreset
    public var source: Source
}

/// What PCGamingWiki says a game offers. A value is nil where the page doesn't say.
public struct GameOptionsInfo: Codable, Sendable, Equatable {
    public var page: String
    public var hasVsync: Bool?
    public var hasUpscaling: Bool?
    public var upscalingTech: String?
    public var supports60: Bool?
    public var supports120: Bool?
    public var hasWindowed: Bool?
    public var hasAntialiasing: Bool?

    /// Reads the `{{Video ...}}` block of a page's wikitext.
    public static func parse(wikitext: String, page: String) -> GameOptionsInfo? {
        guard let start = wikitext.range(of: "{{Video"),
              let end = wikitext.range(of: "\n}}", range: start.upperBound..<wikitext.endIndex) else { return nil }
        var fields: [String: String] = [:]
        for line in wikitext[start.upperBound..<end.lowerBound].split(separator: "\n") where line.hasPrefix("|") {
            let parts = line.dropFirst().split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            fields[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        func flag(_ key: String) -> Bool? {
            switch fields[key]?.lowercased() {
            case "true", "limited", "hackable", "always on": true
            case "false", "n/a": false
            default: nil
            }
        }
        let tech = fields["upscaling tech"].flatMap { $0.isEmpty ? nil : $0 }
        return GameOptionsInfo(page: page, hasVsync: flag("vsync"), hasUpscaling: flag("upscaling"), upscalingTech: tech,
                               supports60: flag("60 fps"), supports120: flag("120 fps"), hasWindowed: flag("windowed"),
                               hasAntialiasing: flag("antialiasing"))
    }
}

public enum SettingsAdvisor {
    public static func advice(curated: CuratedGameSettings?, info: GameOptionsInfo?, tier: MacTier) -> SettingsAdvice {
        if let curated {
            let rows = curated.settings.map { row -> SettingsAdvice.Row in
                let value = tier == .entry ? row.entry : (tier == .mid ? row.mid : row.high)
                return SettingsAdvice.Row(name: row.name, value: value, why: row.why)
            }
            return SettingsAdvice(target: curated.target.value(tier), note: curated.note, rows: rows,
                                  preset: GamePreset(rawValue: curated.cellarPreset.value(tier)) ?? .balanced, source: .curated)
        }
        return general(info: info, tier: tier)
    }

    /// Every game has most of these. Where PCGamingWiki says one is missing, it's left out.
    static func general(info: GameOptionsInfo?, tier: MacTier) -> SettingsAdvice {
        func pick(_ entry: String, _ mid: String, _ high: String) -> String {
            tier == .entry ? entry : (tier == .mid ? mid : high)
        }
        var rows = [
            SettingsAdvice.Row(name: "Overall graphics quality", value: pick("Low", "Medium", "High"), why: "Start here, then raise it if it stays smooth."),
            SettingsAdvice.Row(name: "Resolution", value: pick("About 1280×800", "About 1600×1000", "Native"), why: "The biggest single change on a Mac."),
        ]
        if info?.supports60 != false {
            rows.append(.init(name: "Frame limit", value: pick("40 fps", "60 fps", "60 fps or more"), why: "If the game has one. A limit means steadier play, less heat and more battery."))
        }
        if info?.hasVsync != false {
            rows.append(.init(name: "Vsync", value: pick("Off", "Off", "On"), why: "Below 60 fps, vsync can hold you down to 30."))
        }
        if info?.hasUpscaling == true, info?.upscalingTech?.contains("FSR") == true {
            rows.append(.init(name: "Upscaling", value: pick("FSR, Performance", "FSR, Balanced", "FSR, Quality"), why: "Draws fewer pixels and sharpens them up. DLSS needs an NVIDIA card, so it won't work here."))
        }
        if info?.hasAntialiasing != false {
            rows.append(.init(name: "Antialiasing", value: pick("Off or lowest", "Low", "Medium"), why: "Costly, and a Mac's screen is already sharp."))
        }
        rows.append(.init(name: "Shadows", value: pick("Low", "Medium", "High"), why: "Usually one of the heaviest options."))
        rows.append(.init(name: "Motion blur", value: pick("Off", "Off", "Your choice"), why: "If the game has it. Not worth the cost at lower frame rates."))
        let target = pick("30–40 fps", "45–60 fps", "60 fps")
        let source: SettingsAdvice.Source = info.map { .wiki(page: $0.page) } ?? .general
        return SettingsAdvice(target: target, note: nil, rows: rows, preset: tier == .high ? .quality : .balanced, source: source)
    }
}

/// Looks up what a game offers on PCGamingWiki and remembers it, so it also works offline.
public actor GameOptionsService {
    static let freshness: TimeInterval = 30 * 86_400
    let file: URL
    var cache: [String: Entry] = [:]
    var loaded = false

    struct Entry: Codable {
        var info: GameOptionsInfo?
        var checked: Date
    }

    public init(paths: CellarPaths) {
        file = paths.cache.appending(path: "game-options.json")
    }

    public func info(appID: String, name: String) async -> GameOptionsInfo? {
        if !loaded {
            loaded = true
            if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) { cache = saved }
        }
        if let entry = cache[appID], Date().timeIntervalSince(entry.checked) < Self.freshness { return entry.info }
        var components = URLComponents(string: "https://www.pcgamingwiki.com/w/api.php")!
        let page = name.replacingOccurrences(of: " ", with: "_")
        components.queryItems = [.init(name: "action", value: "parse"), .init(name: "page", value: page),
                                 .init(name: "prop", value: "wikitext"), .init(name: "redirects", value: "1"), .init(name: "format", value: "json")]
        struct Response: Decodable {
            struct Parse: Decodable {
                struct Text: Decodable {
                    var text: String
                    enum CodingKeys: String, CodingKey { case text = "*" }
                }
                var wikitext: Text
            }
            var parse: Parse?
        }
        guard let url = components.url, let (data, reply) = try? await URLSession.shared.data(from: url),
              (reply as? HTTPURLResponse)?.statusCode == 200 else {
            return cache[appID]?.info   // No network: what's saved, and ask again next time.
        }
        let text = (try? JSONDecoder().decode(Response.self, from: data))?.parse?.wikitext.text
        let info = text.flatMap { GameOptionsInfo.parse(wikitext: $0, page: page) }
        cache[appID] = Entry(info: info, checked: Date())
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(cache).write(to: file, options: .atomic)
        return info
    }
}
