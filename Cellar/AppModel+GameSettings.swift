import CellarKit
import Foundation

/// Recommended settings for each game: researched for the ones Cellar knows, general ones for the rest.
extension AppModel {
    /// Reads the Mac's specs once, and the research file that ships with the app.
    private func loadSettingsResearch() async {
        if macSpecs == nil { macSpecs = await Task.detached { MacSpecs.current() }.value }
        guard curatedSettings == nil else { return }
        guard let url = Bundle.main.url(forResource: "game-settings", withExtension: "json"), let data = try? Data(contentsOf: url) else {
            curatedSettings = [:]
            return
        }
        curatedSettings = (try? JSONDecoder().decode([String: CuratedGameSettings].self, from: data)) ?? [:]
    }

    func loadAdvice(for game: Game) async {
        await loadSettingsResearch()
        guard let specs = macSpecs else { return }
        let curated = curatedSettings?[game.id]
        let info = curated == nil ? await gameOptions.info(appID: game.id, name: game.name) : nil
        settingsAdvice[game.id] = SettingsAdvisor.advice(curated: curated, info: info, tier: specs.tier)
    }

    /// Only touches Cellar's own preset. Options inside a game are for the player to set.
    func usePreset(_ preset: GamePreset, for game: Game) {
        updateSettings(for: game) { $0.preset = preset; $0.frameCap = nil }
        toast = "\(game.name) uses the \(preset.title) preset from its next launch."
    }
}
