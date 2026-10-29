import Foundation

/// Someone the signed-in Steam account knows, with what their public profile says right now.
public struct SteamFriend: Sendable, Equatable, Identifiable, Codable {
    public enum State: String, Sendable, Codable {
        case inGame, online, away, offline, unknown
    }

    public var id: String          // SteamID64
    public var name: String
    public var avatar: URL?
    public var state: State
    /// The game they're in, when `state == .inGame`.
    public var game: String?
    public var statusText: String?

    public var sortRank: Int {
        switch state {
        case .inGame: 0
        case .online: 1
        case .away: 2
        case .unknown: 3
        case .offline: 4
        }
    }
}

/// Friends come from the Windows Steam client's own files (no API key): the signed-in user's
/// `localconfig.vdf` lists the people Steam has seen with them. Status comes from each person's
/// public community profile (`?xml=1`); private profiles show as unknown.
public actor FriendsService {
    let steam: Steam
    var cache: [String: (SteamFriend, Date)] = [:]
    static let steamID64Base: UInt64 = 76_561_197_960_265_728
    static let freshness: TimeInterval = 60

    public init(steam: Steam) { self.steam = steam }

    /// The signed-in account's 32-bit ID (the `userdata` folder name).
    nonisolated func accountID() -> String? {
        guard let vdf = try? VDF.parse(contentsOf: steam.steamDir.appending(path: "config/loginusers.vdf")),
              let users = vdf["users"] else { return nil }
        let recent = users.pairs.first { $0.1["MostRecent"]?.string == "1" } ?? users.pairs.first
        guard let id64 = recent.flatMap({ UInt64($0.0) }), id64 > Self.steamID64Base else { return nil }
        return String(id64 - Self.steamID64Base)
    }

    /// Everyone in the local friends cache except the user themself, without status yet.
    public nonisolated func knownFriends() -> [SteamFriend] {
        guard let me = accountID() else { return [] }
        let url = steam.steamDir.appending(path: "userdata/\(me)/config/localconfig.vdf")
        guard let vdf = try? VDF.parse(contentsOf: url),
              let friends = vdf["UserLocalConfigStore"]?["friends"] else { return [] }
        return friends.pairs.compactMap { key, value in
            guard key != me, let account = UInt64(key), case .object = value else { return nil }
            let name = value["name"]?.string ?? value["NameHistory"]?["0"]?.string ?? "Steam friend"
            let avatar = value["avatar"]?.string.flatMap { hash in
                URL(string: "https://avatars.fastly.steamstatic.com/\(hash)_medium.jpg")
            }
            return SteamFriend(id: String(account + Self.steamID64Base), name: name, avatar: avatar,
                               state: .unknown, game: nil, statusText: nil)
        }
    }

    /// Known friends with fresh status, people in games first. Four profile lookups at a time.
    public func friendsWithStatus(limit: Int = 60) async -> [SteamFriend] {
        let known = Array(knownFriends().prefix(limit))
        var result: [SteamFriend] = []
        await withTaskGroup(of: SteamFriend.self) { group in
            var iterator = known.makeIterator()
            func next() -> SteamFriend? { iterator.next() }
            for _ in 0..<4 {
                guard let friend = next() else { break }
                group.addTask { await self.status(for: friend) }
            }
            while let done = await group.next() {
                result.append(done)
                if let friend = next() { group.addTask { await self.status(for: friend) } }
            }
        }
        return result.sorted { ($0.sortRank, $0.name.lowercased()) < ($1.sortRank, $1.name.lowercased()) }
    }

    func status(for friend: SteamFriend) async -> SteamFriend {
        if let (cached, date) = cache[friend.id], Date().timeIntervalSince(date) < Self.freshness { return cached }
        var updated = friend
        if let url = URL(string: "https://steamcommunity.com/profiles/\(friend.id)/?xml=1"),
           let (data, _) = try? await URLSession.shared.data(from: url) {
            let profile = Self.parseProfile(String(decoding: data, as: UTF8.self))
            updated.state = profile.state
            updated.game = profile.game
            updated.statusText = profile.statusText
            if let name = profile.name, !name.isEmpty { updated.name = name }
            if let avatar = profile.avatar { updated.avatar = avatar }
        }
        cache[friend.id] = (updated, Date())
        return updated
    }

    struct Profile {
        var state: SteamFriend.State = .unknown
        var game: String?
        var statusText: String?
        var name: String?
        var avatar: URL?
    }

    static func parseProfile(_ xml: String) -> Profile {
        func tag(_ name: String, in text: String) -> String? {
            guard let open = text.range(of: "<\(name)>"), let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
            var value = String(text[open.upperBound..<close.lowerBound])
            if value.hasPrefix("<![CDATA["), value.hasSuffix("]]>") { value = String(value.dropFirst(9).dropLast(3)) }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var p = Profile()
        p.name = tag("steamID", in: xml)
        p.avatar = tag("avatarMedium", in: xml).flatMap(URL.init(string:))
        if tag("privacyState", in: xml) != "public" { return p }
        let message = tag("stateMessage", in: xml)?.replacingOccurrences(of: "<br/>", with: " ")
        switch tag("onlineState", in: xml) {
        case "in-game":
            p.state = .inGame
            p.game = tag("inGameInfo", in: xml).flatMap { tag("gameName", in: $0) }
        case "online":
            p.state = (message?.localizedCaseInsensitiveContains("away") == true || message?.localizedCaseInsensitiveContains("snooze") == true) ? .away : .online
        case "offline":
            p.state = .offline
        default:
            break
        }
        p.statusText = message
        return p
    }

    /// Opens a chat with them in Windows Steam's friends window (pass to `Steam.Mode.url`).
    public static func chatLink(_ friend: SteamFriend) -> String {
        "steam://friends/message/\(friend.id)"
    }
}
