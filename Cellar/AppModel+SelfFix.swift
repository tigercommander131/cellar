import CellarKit
import Foundation

/// A game that closes right after starting often just needs another graphics option. Cellar tries the
/// others in turn, keeps the one that works, and puts things back if none does.
extension AppModel {
    struct SelfFixAttempt {
        var tried: [GraphicsBackend]
        /// The Mac's own setting from before, to restore if nothing works (nil means none).
        var originalOverride: GraphicsBackend?
        var preset: GamePreset?
    }

    func setSelfFixGames(_ on: Bool) {
        selfFixGames = on
        var state = core.loadState()
        state.selfFixGames = on ? nil : false
        try? core.saveState(state)
    }

    /// Called when a game has been up long enough to count as having started.
    func checkSelfFixWorked(_ id: String) {
        guard selfFixes.removeValue(forKey: id) != nil, let game = games.first(where: { $0.id == id }) else { return }
        toast = "\(game.name) works on \(game.profile.backend.shortName). Cellar will use that from now on."
    }

    /// Called when a game closed within seconds of starting.
    func handleQuickExit(_ id: String) {
        let stoppedOnPurpose = stoppedByUser
        stoppedByUser = false
        guard let game = games.first(where: { $0.id == id }), selfFixGames, !stoppedOnPurpose else {
            selfFixes[id] = nil
            return
        }
        // Only a launch from Cellar in the last couple of minutes. Other exits aren't Cellar's to act on.
        guard let launched = lastLaunch[id], Date().timeIntervalSince(launched) < 120 else { return }
        let override = core.profiles.override(id)?.graphics
        var attempt = selfFixes[id]
        // The player chose this option themself, so leave it alone.
        if attempt == nil, override != nil { return }
        if attempt == nil { attempt = SelfFixAttempt(tried: [], originalOverride: nil, preset: lastLaunchPreset[id]) }
        attempt?.tried.append(game.profile.backend)
        guard var attempt else { return }

        let facts = compatibilityFacts[id]
        if let next = BackendFallback.next(tried: attempt.tried, apis: facts?.graphicsAPIs ?? [], is32Bit: facts?.is32Bit) {
            selfFixes[id] = attempt
            updateSettings(for: game) { $0.graphics = next }
            toast = "\(game.name) closed right after starting. Trying \(next.shortName)…"
            let retry = games.first { $0.id == id } ?? game
            startRetry(retry, on: next, preset: attempt.preset)
        } else {
            selfFixes[id] = nil
            attempt.tried = []
            updateSettings(for: game) { $0.graphics = attempt.originalOverride }
            alert = "\(game.name) closed right after starting, on every graphics option that suits it. It may need a fix Cellar doesn't have yet, or its anti-cheat may be stopping it."
        }
    }

    /// Settings are saved through a background refresh, so give them a moment to land.
    private func startRetry(_ game: Game, on backend: GraphicsBackend, preset: GamePreset?) {
        Task {
            try? await Task.sleep(for: .seconds(1))
            launching = game.id
            lastLaunch[game.id] = Date()
            startSteam(.play(appID: game.id, args: []), preset: preset) { [weak self] in self?.launching = nil }
        }
    }
}
