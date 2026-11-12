import CellarKit
import Foundation
import Network
import SwiftUI

/// Picks Steam's online or offline mode by itself: from a real check of the network, every time the
/// network changes and before Steam starts, and from Steam's own log if it gets stuck signing in.
extension AppModel {
    struct SteamStatus {
        var title: String
        var detail: String
        var color: Color
    }

    var steamStatus: SteamStatus {
        if switchingConnection {
            return SteamStatus(title: "Switching…", detail: "Restarting Steam in the background.", color: .yellow)
        }
        if steamOffline {
            switch (connectionMode, reachability) {
            case (.offline, _):
                return SteamStatus(title: "Offline", detail: "You chose offline. Games you've played online still start. Friends, multiplayer and downloads wait.", color: .orange)
            case (_, .noInternet?):
                return SteamStatus(title: "No internet", detail: "Games you've played online still start. Cellar goes back online by itself.", color: .orange)
            default:
                return SteamStatus(title: "Offline", detail: "This network blocks Steam, so Cellar switched to offline. Games you've played online still start, and it goes back online by itself.", color: .orange)
            }
        }
        guard steamRunning else {
            let waiting = connectionMode == .automatic ? "It starts when you press Play, online or offline depending on the network." : "It starts when you press Play."
            return SteamStatus(title: "Steam closed", detail: waiting, color: Color.secondary.opacity(0.5))
        }
        switch steamLogon {
        case .loggedOn:
            let how = connectionMode == .automatic ? "Connected. Cellar switches to offline by itself if this network blocks Steam." : "Connected."
            return SteamStatus(title: "Online", detail: how, color: .green)
        case .connected, .tryingSince:
            return SteamStatus(title: "Connecting…", detail: "Steam is signing in.", color: .yellow)
        case .idle:
            return SteamStatus(title: "Starting…", detail: "Steam is starting.", color: .yellow)
        }
    }

    func updateLogonState() {
        guard steamRunning, !steamOffline, let started = core.loadState().steamSession?.started else {
            steamLogon = .idle
            return
        }
        steamLogon = core.steam.logonState(since: started.addingTimeInterval(-2))
    }

    // MARK: Watching the network

    func startConnectionWatch() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.networkChanged() }
        }
        monitor.start(queue: DispatchQueue(label: "cellar.network"))
        pathMonitor = monitor
        // Networks can start or stop blocking without the Mac seeing a change (a sign-in page, say).
        connectionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                await self?.reconcileConnection()
            }
        }
    }

    private func networkChanged() {
        steamBlockedUntil = nil
        networkChangeTask?.cancel()
        networkChangeTask = Task { [weak self] in
            // Wi-Fi joining sends several changes in a row, and needs a moment to settle.
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            // Its own task: another change arriving mid-check would cancel this one, and a cancelled check
            // reads as "no internet", which took Steam offline on a good network.
            Task { await self?.reconcileConnection() }
        }
    }

    func setConnectionMode(_ mode: ConnectionMode) {
        connectionMode = mode
        var state = core.loadState()
        state.connectionMode = mode == .automatic ? nil : mode
        try? core.saveState(state)
        Task { await reconcileConnection(userAsked: true) }
    }

    /// Checks the network and moves Steam to the matching mode, unless a game is running.
    func reconcileConnection(userAsked: Bool = false) async {
        guard phase == .ready, !checkingConnection, !switchingConnection, steamUser != nil else { return }
        checkingConnection = true
        defer { checkingConnection = false }

        var reach = await checkedReachability()
        reachability = reach
        var wantsOffline = connectionMode.wantsOffline(reach)
        let core = self.core
        steamOffline = core.steam.offlineMode
        guard wantsOffline != steamOffline else {
            connectionSwitchPending = false
            return
        }

        let running = await Task.detached { core.isSteamRunning() }.value
        if !running {
            try? core.steam.setOfflineMode(wantsOffline)
            steamOffline = wantsOffline
            connectionSwitchPending = false
            return
        }
        // A game starting doesn't show as running yet, and restarting Steam would kill it.
        if runningGame != nil || launching != nil {
            connectionSwitchPending = true
            if userAsked { toast = "Steam switches when your game closes." }
            return
        }
        if !userAsked {
            // A restart costs half a minute, so a blip in the Wi-Fi shouldn't cause one.
            if let last = lastConnectionSwitch, Date().timeIntervalSince(last) < 60 { return }
            if wantsOffline {
                try? await Task.sleep(for: .seconds(15))
                reach = await checkedReachability()
                reachability = reach
                wantsOffline = connectionMode.wantsOffline(reach)
                guard wantsOffline != steamOffline, runningGame == nil, launching == nil else { return }
            }
        }
        await switchSteam(offline: wantsOffline, announce: true)
    }

    /// The network check, minus what Steam's own log has already disproved: on some networks the check
    /// passes but Steam can't sign in. That's remembered for half an hour, or until the network changes,
    /// so Steam isn't put back online every five minutes to hang at "Connecting…".
    private func checkedReachability() async -> SteamReachability {
        let reach = await SteamConnectivity.probe()
        if reach == .reachable, let until = steamBlockedUntil, Date() < until { return .blocked }
        return reach
    }

    /// `thenStart` runs instead of reopening Steam in the background.
    private func switchSteam(offline: Bool, announce: Bool, thenStart mode: Steam.Mode? = nil, preset: GamePreset? = nil) async {
        switchingConnection = true
        lastConnectionSwitch = Date()
        connectionSwitchPending = false
        logonWatch?.cancel()
        let core = self.core
        do {
            try await Task.detached { try core.setSteamOffline(offline, quietly: true, thenStart: mode, preset: preset) }.value
            steamOffline = offline
            if announce {
                toast = offline ? "Steam can't connect on this network, so it's offline. Games still start." : "Steam is back online."
            }
            // Back online by itself: make sure it really signs in, or go offline again.
            if !offline, mode == nil, connectionMode == .automatic { watchLogon(since: Date(), retry: nil, preset: nil) }
        } catch {
            alert = error.localizedDescription
        }
        switchingConnection = false
        await refresh()
    }

    // MARK: Starting Steam

    /// Every start of Steam comes through here, so it always starts in the mode the network needs.
    func startSteam(_ mode: Steam.Mode, preset: GamePreset? = nil, onError: (@MainActor () -> Void)? = nil) {
        let core = self.core
        Task {
            while switchingConnection || installingPack { try? await Task.sleep(for: .milliseconds(300)) }
            let wasRunning = await Task.detached { core.isSteamRunning() }.value
            if !wasRunning, steamUser != nil {
                let reach = connectionMode == .automatic ? await SteamConnectivity.probe() : (reachability ?? .reachable)
                reachability = reach
                let offline = connectionMode.wantsOffline(reach)
                if offline != core.steam.offlineMode { try? core.steam.setOfflineMode(offline) }
                steamOffline = offline
            }
            let started = Date()
            perform({ try $0.launchSteam(mode, preset: preset) }, onError: onError)
            if !wasRunning, !steamOffline, connectionMode == .automatic, steamUser != nil {
                watchLogon(since: started, retry: mode, preset: preset)
            }
        }
    }

    /// The check can pass on a network that still stops Steam itself. Steam's log shows that: it keeps
    /// trying and never connects. Then go offline and carry on with whatever was asked for.
    private func watchLogon(since start: Date, retry: Steam.Mode?, preset: GamePreset?) {
        logonWatch?.cancel()
        logonWatch = Task { [weak self] in
            for _ in 0..<36 {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled, !self.steamOffline, self.connectionMode == .automatic else { return }
                switch self.core.steam.logonState(since: start.addingTimeInterval(-2)) {
                case .loggedOn, .connected:
                    return
                case .tryingSince(let first):
                    guard Date().timeIntervalSince(first) >= 45, self.runningGame == nil else { continue }
                    self.reachability = .blocked
                    self.steamBlockedUntil = Date().addingTimeInterval(30 * 60)
                    await self.switchSteam(offline: true, announce: true, thenStart: retry, preset: preset)
                    return
                case .idle:
                    continue
                }
            }
        }
    }

    // MARK: Steam's own pages

    enum SteamPage: String {
        case library = "steam://open/games"
        case store = "steam://store"
        case downloads = "steam://open/downloads"
        case friends = "steam://open/friends"
    }

    func openSteamPage(_ page: SteamPage) {
        startSteam(.url(page.rawValue))
    }

    func restartSteam() {
        let core = self.core
        Task {
            switchingConnection = true
            await Task.detached { core.stopSteam() }.value
            switchingConnection = false
            startSteam(.open)
        }
    }

    func quitSteam() {
        let core = self.core
        Task.detached { core.stopSteam() }
    }
}
