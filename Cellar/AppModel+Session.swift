import CellarKit
import Foundation

/// Notices games starting and stopping: what the overlay's stats, the Will It Run history and the
/// end-of-game summary all come from.
extension AppModel {
    func trackSessions(running: Set<String>) {
        let known = Set(sessionStarts.keys)
        for id in running.subtracting(known) { gameStarted(id) }
        for id in known.subtracting(running) { gameEnded(id) }
        for id in running where selfFixes[id] != nil {
            if let started = sessionStarts[id], Date().timeIntervalSince(started) >= CellarState.GameStats.quickExitSeconds {
                checkSelfFixWorked(id)
            }
        }
    }

    private func gameStarted(_ id: String) {
        sessionStarts[id] = Date()
        if sessionStarts.count == 1 {
            stats = []
            frameRates = []
            sessionBatteryStart = sampler.sample(gamePIDs: []).battery
            startStats()
            startClipsForGame()
        }
    }

    private func gameEnded(_ id: String) {
        guard let started = sessionStarts.removeValue(forKey: id) else { return }
        let seconds = Date().timeIntervalSince(started)
        var state = core.loadState()
        var all = state.gameStats ?? [:]
        var stats = all[id] ?? CellarState.GameStats()
        stats.record(sessionSeconds: seconds)
        all[id] = stats
        state.gameStats = all
        try? core.saveState(state)
        refreshVerdict(id)
        if seconds < CellarState.GameStats.quickExitSeconds { handleQuickExit(id) }

        if sessionStarts.isEmpty {
            statsTask?.cancel()
            statsTask = nil
            setClipsRecording(false)
            if connectionSwitchPending { Task { await reconcileConnection() } }
            if seconds >= CellarState.GameStats.quickExitSeconds {
                toast = sessionSummary(game: games.first { $0.id == id }?.name, seconds: seconds)
            }
        }
    }

    private func sessionSummary(game: String?, seconds: Double) -> String {
        var line = "\(game ?? "Game"): \(Self.playTime(seconds))"
        let now = sampler.sample(gamePIDs: [])
        if let before = sessionBatteryStart, let after = now.battery, now.onBattery, before > after {
            line += ", used \(Int(((before - after) * 100).rounded()))% battery"
        }
        return line
    }

    static func playTime(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "under a minute" }
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60)h \(minutes % 60)m"
    }

    func totalPlayed(_ id: String) -> Double {
        core.loadState().gameStats?[id]?.playedSeconds ?? 0
    }

    // MARK: Live stats

    /// Light while playing, a bit quicker while the overlay is there to show them.
    private func startStats() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.takeSample()
                let quick = self?.overlay.isVisible == true || self?.clipsRecording == true
                try? await Task.sleep(for: .seconds(quick ? 2 : 10))
            }
        }
    }

    func takeSample() async {
        let core = self.core
        let sampler = self.sampler
        let recorder = clipRecorder
        let (sample, rate) = await Task.detached {
            (sampler.sample(gamePIDs: core.runningGames().map(\.pid)), recorder?.currentFrameRate())
        }.value
        stats.append(sample)
        if stats.count > 300 { stats.removeFirst(stats.count - 300) }
        if let rate {
            frameRates.append(rate)
            if frameRates.count > 300 { frameRates.removeFirst(frameRates.count - 300) }
        }
    }

    // MARK: Notes

    private func notesFile(_ id: String) -> URL {
        core.paths.root.appending(path: "notes/\(id).txt")
    }

    func notes(for id: String) -> String {
        (try? String(contentsOf: notesFile(id), encoding: .utf8)) ?? ""
    }

    func saveNotes(_ text: String, for id: String) {
        let file = notesFile(id)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if text.isEmpty {
            try? FileManager.default.removeItem(at: file)
        } else {
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    func quitGame() {
        let core = self.core
        launching = nil
        stoppedByUser = true
        selfFixes = [:]
        overlay.hide()
        Task.detached { core.stopGames() }
    }
}
