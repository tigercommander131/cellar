import AppIntents
import CellarKit
import CoreSpotlight
import Foundation

/// An installed game, as Siri, Spotlight and Shortcuts see it.
struct GameEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Game"
    static let defaultQuery = GameQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet()
        attributes.title = name
        attributes.displayName = name
        attributes.contentDescription = "Play in Cellar"
        return attributes
    }
}

struct GameQuery: EntityStringQuery {
    private func installed() -> [GameEntity] {
        CellarCore().steam.apps().filter { $0.isInstalled }.map { GameEntity(id: $0.id, name: $0.name) }
    }

    func entities(for identifiers: [String]) async throws -> [GameEntity] {
        installed().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [GameEntity] {
        installed().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [GameEntity] {
        installed()
    }
}

struct PlayGameIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Game"
    static let description = IntentDescription("Starts a game in Cellar.")
    static let openAppWhenRun = true

    @Parameter(title: "Game") var game: GameEntity

    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$game)") }

    init() {}
    init(game: GameEntity) { self.game = game }

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = AppModel.shared
        model.start()
        if let url = URL(string: "cellar://play/\(game.id)") { model.handle(url) }
        return .result()
    }
}

/// What Spotlight runs when a game itself is picked from its results.
struct OpenGameIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Game"

    @Parameter(title: "Game") var target: GameEntity

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = AppModel.shared
        model.start()
        model.focusedGameID = target.id
        model.tab = .games
        model.showAllGames = false
        return .result()
    }
}

struct SaveClipIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Clip"
    static let description = IntentDescription("Saves the last moments of the game you're playing, if Clips are on.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard AppModel.shared.clipsRecording else { return .result(dialog: "Clips are off. Turn them on in the overlay first.") }
        AppModel.shared.saveClip()
        return .result(dialog: "Saved a clip.")
    }
}

struct QuitGameIntent: AppIntent {
    static let title: LocalizedStringResource = "Quit Game"
    static let description = IntentDescription("Force-quits the game you're playing. Steam stays open.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let game = AppModel.shared.runningGame else { return .result(dialog: "No game is running.") }
        AppModel.shared.quitGame()
        return .result(dialog: "Closed \(game.name).")
    }
}

struct OpenSteamIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Steam"
    static let description = IntentDescription("Opens Steam in Cellar.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.start()
        AppModel.shared.openSteam()
        return .result()
    }
}

struct CellarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayGameIntent(), phrases: [
            "Play \(\.$game) in \(.applicationName)",
            "Start \(\.$game) in \(.applicationName)",
            "Launch \(\.$game) with \(.applicationName)",
            "Play a game in \(.applicationName)",
        ], shortTitle: "Play Game", systemImageName: "play.fill")
        AppShortcut(intent: SaveClipIntent(), phrases: [
            "Save a clip in \(.applicationName)",
            "Clip that in \(.applicationName)",
        ], shortTitle: "Save Clip", systemImageName: "record.circle")
        AppShortcut(intent: QuitGameIntent(), phrases: [
            "Quit my game in \(.applicationName)",
        ], shortTitle: "Quit Game", systemImageName: "stop.fill")
        AppShortcut(intent: OpenSteamIntent(), phrases: [
            "Open Steam in \(.applicationName)",
        ], shortTitle: "Open Steam", systemImageName: "storefront")
    }
}
