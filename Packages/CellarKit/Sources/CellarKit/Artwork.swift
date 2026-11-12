import Foundation

/// Store artwork for a Steam app: portrait library capsule, wide hero, header and logo.
public struct SteamArtwork: Codable, Sendable, Equatable {
    /// The store's name for the app (used for games the user doesn't have installed).
    public var name: String?
    public var capsule: URL?
    public var hero: URL?
    public var header: URL?
    public var logo: URL?

    public init(name: String? = nil, capsule: URL? = nil, hero: URL? = nil, header: URL? = nil, logo: URL? = nil) {
        self.name = name
        self.capsule = capsule
        self.hero = hero
        self.header = header
        self.logo = logo
    }
}

/// Looks up artwork through Steam's store API (new games keep their images under hashed
/// paths, so plain CDN URLs don't work for them) and caches the answer on disk.
public actor ArtworkService {
    let cacheFile: URL
    var cache: [String: SteamArtwork] = [:]
    var loaded = false
    /// When the store last didn't answer, so the next try waits.
    var lastFailure: Date?

    static let cdn = "https://shared.akamai.steamstatic.com/store_item_assets/"

    public init(paths: CellarPaths) {
        // v2: earlier versions saved fallback addresses after network failures, which never load
        // for newer games, so those entries are discarded.
        cacheFile = paths.artwork.appending(path: "index-v2.json")
    }

    public func artwork(for appIds: [String]) async -> [String: SteamArtwork] {
        loadIfNeeded()
        let missing = appIds.filter { cache[$0] == nil }
        // The library asks every few seconds. On a network that swallows the request, each ask would
        // otherwise hold the whole refresh until it times out.
        let waiting = lastFailure.map { Date().timeIntervalSince($0) < 60 } ?? false
        if !missing.isEmpty, !waiting {
            for chunk in stride(from: 0, to: missing.count, by: 50).map({ Array(missing[$0..<min($0 + 50, missing.count)]) }) {
                // No answer (school Wi-Fi, offline): use a guess for now, but ask again next time.
                guard let found = try? await fetch(chunk) else {
                    lastFailure = Date()
                    break
                }
                for id in chunk { cache[id] = found[id] ?? Self.fallback(id) }
            }
            save()
        }
        return appIds.reduce(into: [:]) { $0[$1] = cache[$1] ?? Self.fallback($1) }
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
        var urlRequest = URLRequest(url: components.url!)
        urlRequest.timeoutInterval = 6
        let (data, _) = try await URLSession.shared.data(for: urlRequest)

        struct Response: Decodable {
            struct Body: Decodable { var store_items: [Item]? }
            struct Item: Decodable {
                var appid: Int?
                var name: String?
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
                name: item.name,
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

/// Finds a game's trailer through Steam's store and remembers the answer. Steam serves trailers as
/// HLS streams, which the Mac's video player handles natively.
public actor TrailerService {
    static let freshness: TimeInterval = 7 * 86_400
    let file: URL
    var cache: [String: Entry] = [:]
    var loaded = false

    struct Entry: Codable {
        var url: URL?
        var checked: Date
    }

    public init(paths: CellarPaths) {
        file = paths.cache.appending(path: "trailers.json")
    }

    public func trailer(appID: String) async -> URL? {
        if !loaded {
            loaded = true
            let decoder = JSONDecoder()
            if let data = try? Data(contentsOf: file), let saved = try? decoder.decode([String: Entry].self, from: data) { cache = saved }
        }
        if let entry = cache[appID], Date().timeIntervalSince(entry.checked) < Self.freshness { return entry.url }
        guard let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&filters=movies"),
              let (data, reply) = try? await URLSession.shared.data(from: url), (reply as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return cache[appID]?.url }
        let found = Self.bestTrailer(fromStoreEntry: root[appID] as? [String: Any])
        cache[appID] = Entry(url: found, checked: Date())
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(cache).write(to: file, options: .atomic)
        return found
    }

    /// The first one Steam highlights, else the first it lists.
    static func bestTrailer(fromStoreEntry entry: [String: Any]?) -> URL? {
        guard let movies = (entry?["data"] as? [String: Any])?["movies"] as? [[String: Any]] else { return nil }
        let chosen = movies.first { ($0["highlight"] as? Bool) == true } ?? movies.first
        return (chosen?["hls_h264"] as? String).flatMap(URL.init(string:))
    }
}
