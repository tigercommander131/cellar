import CellarKit
import Foundation

/// A game that closes right after starting often just needs another graphics option. Cellar offers the
/// others in turn, keeps the one that works, and puts things back if none does.
extension AppModel {
    struct SelfFixAttempt {
        var tried: [GraphicsBackend]
        /// The Mac's own setting from before, to restore if nothing works (nil means none).
        var originalOverride: GraphicsBackend?
        var preset: GamePreset?
    }

    struct SelfFixPrompt {
        var game: Game
        var next: GraphicsBackend
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

    /// Called when a game closed within seconds of starting. Cellar can't tell a crash from someone
    /// quitting, so it asks instead of changing anything by itself.
    func handleQuickExit(_ id: String) {
        let stoppedOnPurpose = stoppedByUser
        stoppedByUser = false
        guard let game = games.first(where: { $0.id == id }), selfFixGames, !stoppedOnPurpose else {
            endSelfFix(id)
            return
        }
        // Only a launch from Cellar in the last couple of minutes. Other exits aren't Cellar's to act on.
        guard let launched = lastLaunch[id], Date().timeIntervalSince(launched) < 120 else { return }
        var attempt = selfFixes[id]
        if attempt == nil {
            // The player chose this option themself, so leave it alone.
            if core.profiles.override(id)?.graphics != nil { return }
            // It already runs here, so this was almost certainly someone closing it.
            let state = core.loadState()
            if (state.gameStats?[id]?.playedSeconds ?? 0) >= CompatibilityAssessor.provenSeconds || state.compatibilityReports?[id] == true { return }
            attempt = SelfFixAttempt(tried: [], originalOverride: nil, preset: lastLaunchPreset[id])
        }
        attempt?.tried.append(game.profile.backend)
        guard let attempt else { return }
        selfFixes[id] = attempt

        let facts = compatibilityFacts[id]
        if let next = BackendFallback.next(tried: attempt.tried, apis: facts?.graphicsAPIs ?? [], is32Bit: facts?.is32Bit) {
            selfFixPrompt = SelfFixPrompt(game: game, next: next)
        } else {
            alert = "\(game.name) closed right after starting, on every graphics option that suits it. It may need a fix Cellar doesn't have yet, or its anti-cheat may be stopping it."
            endSelfFix(id)
        }
    }

    func answerSelfFixPrompt(tryIt: Bool) {
        guard let prompt = selfFixPrompt else { return }
        selfFixPrompt = nil
        let id = prompt.game.id
        guard tryIt, let attempt = selfFixes[id] else { return endSelfFix(id) }
        updateSettings(for: prompt.game) { $0.graphics = prompt.next }
        toast = "Trying \(prompt.next.shortName)…"
        startRetry(prompt.game, on: prompt.next, preset: attempt.preset)
    }

    /// Stops trying. Whatever was being tried only stays if it worked, which removes the attempt first.
    private func endSelfFix(_ id: String) {
        guard let attempt = selfFixes.removeValue(forKey: id), let game = games.first(where: { $0.id == id }) else { return }
        updateSettings(for: game) { $0.graphics = attempt.originalOverride }
    }

    /// Settings are saved through a background refresh, so give them a moment to land.
    private func startRetry(_ game: Game, on backend: GraphicsBackend, preset: GamePreset?) {
        Task {
            try? await Task.sleep(for: .seconds(1))
            markLaunching(game.id)
            lastLaunch[game.id] = Date()
            startSteam(.play(appID: game.id, args: []), preset: preset) { [weak self] in self?.launching = nil }
        }
    }
}
