import Foundation

/// Store artwork for a Steam app: portrait library capsule, wide hero, header and logo.
public struct SteamArtwork: Codable, Sendable, Equatable {
    public var capsule: URL?
    public var hero: URL?
    public var header: URL?
    public var logo: URL?
}

/// Looks up artwork through Steam's store API (new games keep their images under hashed
/// paths, so plain CDN URLs don't work for them) and caches the answer on disk.
public actor ArtworkService {
    let cacheFile: URL
    var cache: [String: SteamArtwork] = [:]
    var loaded = false

    static let cdn = "https://shared.akamai.steamstatic.com/store_item_assets/"

    public init(paths: CellarPaths) {
        cacheFile = paths.artwork.appending(path: "index.json")
    }

    public func artwork(for appIds: [String]) async -> [String: SteamArtwork] {
        loadIfNeeded()
        let missing = appIds.filter { cache[$0] == nil }
        if !missing.isEmpty {
            for chunk in stride(from: 0, to: missing.count, by: 50).map({ Array(missing[$0..<min($0 + 50, missing.count)]) }) {
                let found = (try? await fetch(chunk)) ?? [:]
                for id in chunk { cache[id] = found[id] ?? Self.fallback(id) }
            }
            save()
        }
        return appIds.reduce(into: [:]) { $0[$1] = cache[$1] }
    }

    static func fallback(_ id: String) -> SteamArtwork {
        let base = cdn + "steam/apps/\(id)/"
        return SteamArtwork(capsule: URL(string: base + "library_600x900_2x.jpg"), hero: URL(string: base + "library_hero.jpg"),
                            header: URL(string: base + "header.jpg"), logo: URL(string: base + "logo.png"))
    }

    func fetch(_ ids: [String]) async throws -> [String: SteamArtwork] {
        let request: [String: Any] = [
            "ids": ids.compactMap { Int($0) }.map { ["appid": $0] },
            "context": ["language": "english", "country_code": Locale.current.region?.identifier ?? "US"],
            "data_request": ["include_assets": true],
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        var components = URLComponents(string: "https://api.steampowered.com/IStoreBrowseService/GetItems/v1/")!
        components.queryItems = [URLQueryItem(name: "input_json", value: json)]
        let (data, _) = try await URLSession.shared.data(from: components.url!)

        struct Response: Decodable {
            struct Body: Decodable { var store_items: [Item]? }
            struct Item: Decodable {
                var appid: Int?
                var assets: Assets?
            }
            struct Assets: Decodable {
                var asset_url_format: String?
                var library_capsule_2x: String?
                var library_capsule: String?
                var library_hero: String?
                var header: String?
                var library_logo: String?
            }
            var response: Body
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        var result: [String: SteamArtwork] = [:]
        for item in decoded.response.store_items ?? [] {
            guard let appid = item.appid, let a = item.assets, let format = a.asset_url_format else { continue }
            func url(_ file: String?) -> URL? {
                file.flatMap { URL(string: Self.cdn + format.replacingOccurrences(of: "${FILENAME}", with: $0)) }
            }
            let fallback = Self.fallback(String(appid))
            result[String(appid)] = SteamArtwork(
                capsule: url(a.library_capsule_2x ?? a.library_capsule) ?? fallback.capsule,
                hero: url(a.library_hero) ?? fallback.hero,
                header: url(a.header) ?? fallback.header,
                logo: url(a.library_logo) ?? fallback.logo
            )
        }
        return result
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: cacheFile), let saved = try? JSONDecoder().decode([String: SteamArtwork].self, from: data) {
            cache = saved
        }
    }

    func save() {
        try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(cache).write(to: cacheFile, options: .atomic)
    }
}
