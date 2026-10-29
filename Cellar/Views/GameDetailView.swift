import CellarKit
import SwiftUI

/// Per-game settings, opened from the slider button next to Play.
struct GameSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let game: Game

    private var override: GameProfile? { model.core.profiles.override(game.id) }
    private var recommended: GraphicsBackend { model.core.profiles.builtIn(game.id)?.graphics ?? .d3dmetal }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Color.clear.frame(height: 120).frame(maxWidth: .infinity)
                    .overlay { ArtworkImage(url: game.artwork?.hero ?? game.artwork?.header) }
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                Text(game.name).font(.title2.weight(.bold)).padding(16)
            }
            .frame(height: 120)

            Form {
                Section {
                    Picker("Graphics", selection: Binding(get: { override?.graphics }, set: { model.setBackend($0, for: game) })) {
                        Text("Recommended (\(recommended.shortName))").tag(GraphicsBackend?.none)
                        Divider()
                        ForEach(GraphicsBackend.allCases, id: \.self) { Text($0.displayName).tag(GraphicsBackend?.some($0)) }
                    }
                    Picker("FPS counter", selection: Binding(get: { override?.metalHUD }, set: { model.setMetalHUD($0, for: game) })) {
                        Text("Default (\(model.showFPS ? "on" : "off"))").tag(Bool?.none)
                        Text("On").tag(Bool?.some(true))
                        Text("Off").tag(Bool?.some(false))
                    }
                    LabeledContent("Memory", value: game.profile.minRAMGB.map { "Wants \($0) GB · this Mac has \(model.host.memoryGB) GB" } ?? "No requirement on file")
                } header: {
                    Text("Performance")
                } footer: {
                    Text("Applies the next time you press Play. Steam restarts if it needs different settings. Games run in macOS Game Mode when fullscreen.")
                }
                if let notes = game.profile.notes {
                    Section("Notes") { Text(notes).foregroundStyle(.secondary) }
                }
                Section("About") {
                    LabeledContent("Size", value: game.app.sizeOnDisk.formattedBytes)
                    LabeledContent("Steam app ID", value: game.id)
                    HStack {
                        Button("Add to Dock") { model.addToDock(game) }
                        Button("Show Files") { model.showInFinder(game) }
                        Button("Store Page") { model.openStorePage(game) }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 600)
    }
}
