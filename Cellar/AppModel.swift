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

    var id: String { app.id }
    var name: String { app.name }
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

    var phase: Phase = .loading
    var setupStep: CellarCore.SetupStep?
    var setupMessage = ""
    var setupProgress: Double?
    var setupError: String?

    var games: [Game] = []
    var steamRunning = false
    var steamUser: String?
    var launching: String?
    var alert: String?
    var lowMemoryMode: Bool

    private var refreshTask: Task<Void, Never>?

    init() {
        artworkService = ArtworkService(paths: core.paths)
        lowMemoryMode = core.lowMemoryMode(host: host)
    }

    var installedGames: [Game] { games.filter { $0.app.isInstalled && !$0.app.isUpdating } }
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
            let games = core.runningGames()
            let ids = running && !games.isEmpty ? core.steam.runningAppIDs() : []
            return (apps, running, ids, core.steam.signedInUser())
        }.value
        let (apps, running, runningIDs, user) = snapshot
        steamRunning = running
        steamUser = user
        let art = await artworkService.artwork(for: apps.map(\.id))
        games = apps.map { app in
            Game(app: app, profile: core.profiles.profile(for: app.id), artwork: art[app.id], isRunning: runningIDs.contains(app.id))
        }
        if let launching, runningIDs.contains(launching) { self.launching = nil }
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
        if let need = game.profile.minRAMGB, host.memoryGB < need {
            alert = "\(game.name) wants \(need) GB of memory and this Mac has \(host.memoryGB) GB. It may stutter or close."
        }
        launching = game.id
        perform { try $0.launchSteam(.play(appID: game.id, args: [])) } onError: { [weak self] in self?.launching = nil }
        Task {
            try? await Task.sleep(for: .seconds(90))
            if launching == game.id { launching = nil }
        }
    }

    func stopAll() {
        let core = self.core
        launching = nil
        Task.detached { core.stopEverything() }
    }

    func setBackend(_ backend: GraphicsBackend?, for game: Game) {
        var override = core.profiles.override(game.id) ?? GameProfile(appId: game.id)
        override.graphics = backend
        if override == GameProfile(appId: game.id) {
            core.profiles.clearOverride(game.id)
        } else {
            try? core.profiles.saveOverride(override)
        }
        Task { await refresh() }
    }

    func setLowMemoryMode(_ on: Bool) {
        lowMemoryMode = on
        var state = core.loadState()
        state.lowMemoryMode = on == host.prefersLowMemoryMode ? nil : on
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
