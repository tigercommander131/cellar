import CellarKit
import Foundation
import Observation
import SwiftUI

/// One row of the library: a Steam app plus what Cellar knows about it.
struct Game: Identifiable, Equatable {
    var app: SteamApp
    var profile: GameProfile
    var artwork: SteamArtwork?
    var isRunning: Bool
    var lastPlayed: Date?

    var id: String { app.id }
    var name: String { app.name }
}

enum Tab: String, CaseIterable, Identifiable {
    case home = "Home", library = "Library", friends = "Friends"
    var id: String { rawValue }
}

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case loading
        case needsSetup
        case settingUp
        case ready
    }

    let core = CellarCore()
    let host = HostCheck.current()
    private let artworkService: ArtworkService
    private let friendsService: FriendsService

    var phase: Phase = .loading
    var setupStep: CellarCore.SetupStep?
    var setupMessage = ""
    var setupProgress: Double?
    var setupError: String?

    var games: [Game] = []
    var steamRunning = false
    var steamUser: String?
    var steamOffline = false
    var launching: String?
    var alert: String?
    var hideSteamWhilePlaying: Bool
    var showFPS: Bool
    /// The game waiting on the "use Battery preset?" question.
    var batteryPromptGame: Game?

    var tab: Tab = .home
    var focusedGameID: String?
    var settingsGame: Game?
    var friends: [SteamFriend] = []
    var friendsLoaded = false
    var toast: String?
    /// The signed-in user's own game and how others can join it, from the Steam client.
    var ownApp: String?
    var ownLobby: String?
    var ownConnect: String?
    var invitedFriends: Set<String> = []
    let overlay = OverlayController()

    private var refreshTask: Task<Void, Never>?
    private var friendsTask: Task<Void, Never>?

    init() {
        artworkService = ArtworkService(paths: core.paths)
        friendsService = FriendsService(steam: core.steam)
        hideSteamWhilePlaying = core.hideSteamWhilePlaying
        showFPS = core.loadState().showFPS ?? false
        overlay.model = self
    }

    /// Installed games, most recently played first.
    var installedGames: [Game] {
        games.filter { $0.app.isInstalled && !$0.app.isUpdating }.sorted {
            switch ($0.lastPlayed, $1.lastPlayed) {
            case let (a?, b?): a > b
            case (_?, nil): true
            case (nil, _?): false
            default: $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    var focusedGame: Game? {
        installedGames.first { $0.id == focusedGameID } ?? installedGames.first
    }

    var friendsInGame: [SteamFriend] { friends.filter { $0.state == .inGame } }
    var friendsOnline: [SteamFriend] { friends.filter { $0.state == .online || $0.state == .away } }
    var downloadingGames: [Game] { games.filter { !$0.app.isInstalled || $0.app.isUpdating } }
    var runningGame: Game? { games.first { $0.isRunning } }

    // MARK: Lifecycle

    func start() {
        phase = core.isSetUp ? .ready : .needsSetup
        startRefreshing()
    }

    func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func refresh() async {
        guard phase == .ready else { return }
        let core = self.core
        let snapshot = await Task.detached { () -> ([SteamApp], Bool, Set<String>, String?) in
            let apps = core.steam.apps()
            let running = core.isSteamRunning()
            return (apps, running, core.runningAppIDs(among: apps), core.steam.signedInUser())
        }.value
        let (apps, running, runningIDs, user) = snapshot
        steamRunning = running
        steamUser = user
        steamOffline = core.steam.offlineMode
        let art = await artworkService.artwork(for: apps.map(\.id))
        let played = core.loadState().lastPlayed ?? [:]
        games = apps.map { app in
            Game(app: app, profile: core.profiles.profile(for: app.id), artwork: art[app.id],
                 isRunning: runningIDs.contains(app.id), lastPlayed: played[app.id])
        }
        if let launching, runningIDs.contains(launching) { self.launching = nil }
        overlay.setHotkeyActive(!runningIDs.isEmpty)
        if runningIDs.isEmpty, overlay.isVisible { overlay.hide() }
    }

    // MARK: Setup

    var manifestURL: URL {
        if let raw = ProcessInfo.processInfo.environment["CELLAR_MANIFEST"] ?? UserDefaults.standard.string(forKey: "manifestURL"), !raw.isEmpty {
            return raw.hasPrefix("http") ? URL(string: raw)! : URL(fileURLWithPath: raw)
        }
        return PackManifest.remoteURL
    }

    func runSetup() {
        phase = .settingUp
        setupError = nil
        setupStep = .checks
        let core = self.core
        let manifestURL = self.manifestURL
        Task {
            do {
                let manifest = try await PackManifest.load(from: manifestURL)
                try await core.setup(manifest: manifest, step: { step in
                    Task { @MainActor in self.setupStep = step }
                }, progress: { text, fraction in
                    Task { @MainActor in
                        self.setupMessage = text
                        self.setupProgress = fraction
                    }
                })
                phase = .ready
                await refresh()
                openSteam()
            } catch {
                setupError = error.localizedDescription
            }
        }
    }

    /// Checks for newer engine, graphics or game-fix packs in the background.
    func checkForPackUpdates() {
        guard phase == .ready else { return }
        let core = self.core
        let manifestURL = self.manifestURL
        Task.detached {
            guard let manifest = try? await PackManifest.load(from: manifestURL) else { return }
            let stale = manifest.packs.filter { !core.packs.isCurrent($0) }
            guard !stale.isEmpty else { return }
            // Engine and graphics updates need everything closed; game fixes don't.
            let busy = core.isSteamRunning() || !core.runningProcesses().isEmpty
            for entry in stale where entry.kind == .profiles || !busy {
                try? await core.packs.install(entry)
            }
        }
    }

    // MARK: Actions

    func openSteam() {
        perform { try $0.launchSteam(.open) }
    }

    func play(_ game: Game) {
        // On battery, offer the lower frame cap, where this game's graphics backend can apply one.
        if HostCheck.isOnBattery, game.profile.backend.supportsFrameCap, game.profile.preset != .battery,
           core.loadState().skipBatteryPrompt != true {
            batteryPromptGame = game
            return
        }
        launch(game)
    }

    func answerBatteryPrompt(usePreset: Bool, dontAskAgain: Bool = false) {
        guard let game = batteryPromptGame else { return }
        batteryPromptGame = nil
        if dontAskAgain {
            var state = core.loadState()
            state.skipBatteryPrompt = true
            try? core.saveState(state)
        }
        launch(game, preset: usePreset ? .battery : nil)
    }

    private func launch(_ game: Game, preset: GamePreset? = nil) {
        if let need = game.profile.minRAMGB, host.memoryGB < need {
            alert = "\(game.name) wants \(need) GB of memory and this Mac has \(host.memoryGB) GB. It may stutter or close."
        }
        launching = game.id
        perform { try $0.launchSteam(.play(appID: game.id, args: []), preset: preset) } onError: { [weak self] in self?.launching = nil }
        Task {
            try? await Task.sleep(for: .seconds(90))
            if launching == game.id { launching = nil }
        }
    }

    /// Steam's offline mode, for networks (like school Wi-Fi) that block Steam's servers.
    func setSteamOffline(_ offline: Bool) {
        steamOffline = offline
        perform { try $0.setSteamOffline(offline) } onError: { [weak self] in
            self?.steamOffline = !offline
        }
        toast = offline ? "Steam is in offline mode. Games start without signing in." : "Steam is back online."
    }

    // MARK: Friends

    func startFriends() {
        guard friendsTask == nil else { return }
        friendsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // The helper is a Wine process: don't start one mid-game unless the overlay is open.
                if runningGame == nil || overlay.isVisible { await refreshFriends() }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Friends from the Steam client when it's running and online, otherwise from public profiles.
    func refreshFriends() async {
        let core = self.core
        let snapshot = steamRunning && !steamOffline ? await Task.detached { try? core.bridgeSnapshot() }.value : nil
        guard let snapshot else {
            friends = await friendsService.friendsWithStatus()
            ownApp = nil
            ownLobby = nil
            ownConnect = nil
            friendsLoaded = true
            return
        }
        let app = snapshot.app ?? 0
        ownApp = app > 0 ? String(app) : nil
        ownLobby = snapshot.lobby == "0" ? nil : snapshot.lobby
        ownConnect = snapshot.connect?.isEmpty == false ? snapshot.connect : nil
        let appIDs = (snapshot.friends ?? []).compactMap(\.app).filter { $0 > 0 }.map(String.init)
        let art = await artworkService.artwork(for: appIDs)
        var names = art.compactMapValues(\.name)
        for game in games { names[game.id] = game.name }
        friends = friendsService.friends(from: snapshot, gameNames: names)
        friendsLoaded = true
    }

    /// One click: starts the game if needed (restarting Steam for its settings) and joins the friend.
    func join(_ friend: SteamFriend) {
        guard let appID = friend.appID, let link = friend.joinLink else { return }
        overlay.hide()
        guard let game = games.first(where: { $0.id == appID && $0.app.isInstalled }) else {
            toast = "You don't have \(friend.game ?? "that game") yet. Steam will offer to install it."
            perform { try $0.launchSteam(.install(appID: appID)) }
            return
        }
        if let other = runningGame, other.id != appID {
            alert = "Close \(other.name) first to join \(friend.name) in \(game.name)."
            return
        }
        focusedGameID = appID
        launching = appID
        toast = "Joining \(friend.name) in \(game.name)…"
        perform { try $0.launchSteam(.join(appID: appID, link: link)) } onError: { [weak self] in
            self?.launching = nil
            self?.openFriendsWindow(after: friend)
        }
    }

    /// Asks Steam to send a game invite for the game being played right now.
    func invite(_ friend: SteamFriend) {
        Task {
            await refreshFriends()
            guard let appID = ownApp else {
                alert = "Start a game first, then invite \(friend.name)."
                return
            }
            let connect: String? = ownLobby.map { "+connect_lobby \($0)" } ?? ownConnect
            guard let connect else {
                toast = "This game isn't sharing a lobby yet. Host one in the game, then invite again."
                return
            }
            let core = self.core
            let friendID = friend.id
            do {
                try await Task.detached { try core.invite(friendID: friendID, appID: appID, connect: connect) }.value
                invitedFriends.insert(friend.id)
                toast = "Invite sent to \(friend.name)."
            } catch {
                openFriendsWindow(after: friend)
            }
        }
    }

    /// The fallback when Join or Invite can't complete: Steam's own friends window.
    private func openFriendsWindow(after friend: SteamFriend) {
        toast = "That didn't work. Opening Steam's chat with \(friend.name) instead."
        chat(with: friend)
    }

    func chat(with friend: SteamFriend) {
        perform { try $0.launchSteam(.url(FriendsService.chatLink(friend))) }
    }

    // MARK: Links (cellar://play/<appid> from Dock shortcuts)

    func handle(_ url: URL) {
        guard url.scheme == "cellar", phase == .ready else { return }
        let parts = [url.host()].compactMap { $0 } + url.pathComponents.filter { $0 != "/" }
        // Any web page can open a cellar:// link, so it can only start games already installed.
        guard parts.first == "play", parts.count == 2,
              let game = installedGames.first(where: { $0.id == parts[1] }) else { return }
        focusedGameID = game.id
        tab = .home
        play(game)
    }

    func addToDock(_ game: Game) {
        Task {
            do {
                let app = try await ShortcutMaker.create(for: game)
                NSWorkspace.shared.activateFileViewerSelecting([app])
                toast = "\(game.name) is in Applications › Cellar Games. Drag it to your Dock."
            } catch {
                alert = "Couldn't make a shortcut: \(error.localizedDescription)"
            }
        }
    }

    /// Changes this Mac's settings for a game. They apply the next time it starts.
    func updateSettings(for game: Game, _ change: (inout GameProfile) -> Void) {
        var override = core.profiles.override(game.id) ?? GameProfile(appId: game.id)
        change(&override)
        saveOverride(override, for: game)
    }

    func setShowFPS(_ on: Bool) {
        showFPS = on
        var state = core.loadState()
        state.showFPS = on ? true : nil
        try? core.saveState(state)
        Task { await refresh() }
    }

    private func saveOverride(_ override: GameProfile, for game: Game) {
        if override == GameProfile(appId: game.id) {
            core.profiles.clearOverride(game.id)
        } else {
            try? core.profiles.saveOverride(override)
        }
        Task { await refresh() }
        if settingsGame?.id == game.id { settingsGame = games.first { $0.id == game.id } }
    }

    func stopAll() {
        let core = self.core
        launching = nil
        Task.detached { core.stopEverything() }
    }

    func setHideSteamWhilePlaying(_ on: Bool) {
        hideSteamWhilePlaying = on
        var state = core.loadState()
        state.hideSteamWhilePlaying = on ? nil : false
        try? core.saveState(state)
    }

    func showInFinder(_ game: Game) {
        let url = URL(fileURLWithPath: game.app.libraryPath).appending(path: "common/\(game.app.installDir)")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openStorePage(_ game: Game) {
        NSWorkspace.shared.open(URL(string: "https://store.steampowered.com/app/\(game.id)")!)
    }

    func openLogs() {
        NSWorkspace.shared.open(core.paths.logs)
    }

    private func perform(_ action: @escaping @Sendable (CellarCore) throws -> Void, onError: (@MainActor () -> Void)? = nil) {
        let core = self.core
        Task {
            do {
                try await Task.detached { try action(core) }.value
            } catch {
                alert = error.localizedDescription
                onError?()
            }
            try? await Task.sleep(for: .seconds(2))
            await refresh()
        }
    }
}
