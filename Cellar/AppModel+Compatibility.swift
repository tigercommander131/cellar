import CellarKit
import CoreSpotlight
import Foundation

/// Will It Run: a verdict for each installed game, kept current as the library and its history change.
extension AppModel {
    func checkCompatibility() {
        let unchecked = installedGames.filter { compatibilityFacts[$0.id] == nil }
        guard !unchecked.isEmpty, compatibilityTask == nil else { return }
        compatibilityTask = Task { [weak self] in
            for game in unchecked {
                guard let self, !Task.isCancelled else { return }
                let folder = URL(fileURLWithPath: game.app.libraryPath).appending(path: "common/\(game.app.installDir)", directoryHint: .isDirectory)
                let facts = await self.compatibility.facts(appID: game.id, name: game.name, installFolder: folder, size: game.app.sizeOnDisk)
                self.compatibilityFacts[game.id] = facts
                self.refreshVerdict(game.id)
            }
            self?.compatibilityTask = nil
        }
    }

    /// Adds this Mac's own history to what's known, and works out the verdict.
    func refreshVerdict(_ id: String) {
        guard let facts = compatibilityFacts[id] else { return }
        verdicts[id] = assess(facts, id: id)
    }

    private func assess(_ facts: CompatibilityFacts, id: String) -> CompatibilityAssessment {
        var facts = facts
        let state = core.loadState()
        facts.playedSeconds = state.gameStats?[id]?.playedSeconds ?? 0
        facts.quickExits = state.gameStats?[id]?.quickExits ?? 0
        facts.report = state.compatibilityReports?[id]
        return CompatibilityAssessor.assess(facts, memoryGB: host.memoryGB)
    }

    /// The player's own verdict beats everything Cellar worked out. nil takes it back.
    func report(_ works: Bool?, for id: String) {
        var state = core.loadState()
        var reports = state.compatibilityReports ?? [:]
        reports[id] = works
        state.compatibilityReports = reports.isEmpty ? nil : reports
        try? core.saveState(state)
        refreshVerdict(id)
    }

    func report(for id: String) -> Bool? {
        core.loadState().compatibilityReports?[id]
    }

    /// A game that isn't installed: public data only.
    func assessOnline(_ match: CompatibilityService.StoreMatch) async -> CompatibilityAssessment {
        let facts = await compatibility.facts(appID: match.id, name: match.name, installFolder: nil, size: 0)
        return assess(facts, id: match.id)
    }

    func install(appID: String) {
        startSteam(.install(appID: appID))
    }

    // MARK: Spotlight and Siri

    func setGamesInSpotlight(_ on: Bool) {
        gamesInSpotlight = on
        var state = core.loadState()
        state.gamesInSpotlight = on ? nil : false
        try? core.saveState(state)
        indexedGames = nil
        syncSpotlight()
    }

    /// Runs when the installed games change: Spotlight's copies, and the games Siri knows by name.
    func syncSpotlight() {
        let games = gamesInSpotlight ? installedGames : []
        let ids = Set(games.map(\.id))
        guard ids != indexedGames, libraryHasArtwork(games) else { return }
        indexedGames = ids
        Task {
            await ShortcutMaker.sync(games)
            CellarShortcuts.updateAppShortcutParameters()
            let entities = games.map { GameEntity(id: $0.id, name: $0.name) }
            try? await CSSearchableIndex.default().deleteAppEntities(ofType: GameEntity.self)
            try? await CSSearchableIndex.default().indexAppEntities(entities)
        }
    }

    /// Icons come from the artwork, so wait until the library has it.
    private func libraryHasArtwork(_ games: [Game]) -> Bool {
        games.allSatisfy { $0.artwork != nil }
    }
}
