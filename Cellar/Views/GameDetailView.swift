import CellarKit
import SwiftUI

/// Per-game settings, opened from the slider button next to Play: a preset, then Advanced.
struct GameSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let game: Game
    @State private var showAdvanced = false
    @State private var launchOptions = ""

    private var override: GameProfile? { model.core.profiles.override(game.id) }
    private var recommended: GraphicsBackend { model.core.profiles.builtIn(game.id)?.graphics ?? .d3dmetal }
    /// Live values: `game` is a snapshot from when the sheet opened.
    private var current: GameProfile { model.core.profiles.profile(for: game.id) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Color.clear.frame(height: 110).frame(maxWidth: .infinity)
                    .overlay { ArtworkImage(url: game.artwork?.hero ?? game.artwork?.header) }
                    .clipped()
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                Text(game.name).font(.title2.weight(.bold)).padding(16)
            }
            .frame(height: 110)

            Form {
                Section {
                    HStack(spacing: 10) {
                        ForEach(GamePreset.allCases) { preset in
                            PresetCard(preset: preset, selected: (current.preset ?? .quality) == preset,
                                       backend: current.backend) {
                                model.updateSettings(for: game) { $0.preset = preset; $0.frameCap = nil }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("Preset")
                } footer: {
                    if !current.backend.supportsFrameCap {
                        Text("\(current.backend.shortName) can't limit frame rate from Cellar. Use vsync or the frame limit in the game's own settings to save power.")
                    }
                }

                Section("Advanced", isExpanded: $showAdvanced) {
                    Picker("Graphics", selection: binding(\.graphics)) {
                        Text("Recommended (\(recommended.shortName))").tag(GraphicsBackend?.none)
                        Divider()
                        ForEach(GraphicsBackend.allCases, id: \.self) { Text($0.displayName).tag(GraphicsBackend?.some($0)) }
                    }
                    Picker("Frame limit", selection: binding(\.frameCap)) {
                        Text("From preset").tag(Int?.none)
                        Text("None").tag(Int?.some(0))
                        ForEach([30, 40, 60, 120], id: \.self) { Text("\($0) fps").tag(Int?.some($0)) }
                    }
                    .disabled(!current.backend.supportsFrameCap)
                    Picker("FPS counter", selection: binding(\.metalHUD)) {
                        Text("Default (\(model.showFPS ? "on" : "off"))").tag(Bool?.none)
                        Text("On").tag(Bool?.some(true))
                        Text("Off").tag(Bool?.some(false))
                    }
                    Toggle("Retina resolution (sharper, slower)", isOn: toggle(\.retina))
                    Toggle("Steam overlay (experimental)", isOn: toggle(\.steamOverlay))
                    TextField("Launch options", text: $launchOptions, prompt: Text("e.g. -novid"))
                        .onSubmit(saveLaunchOptions)
                    Text("Steam's overlay is only needed for a game's own Invite button. It can crash some games; Cellar's overlay can't. Changes apply the next time you press Play, and Steam restarts if needed.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let notes = current.notes {
                    Section("Notes") { Text(notes).foregroundStyle(.secondary) }
                }
                Section("About") {
                    LabeledContent("Size", value: game.app.sizeOnDisk.formattedBytes)
                    LabeledContent("Steam app ID", value: game.id)
                    LabeledContent("Memory", value: current.minRAMGB.map { "Wants \($0) GB · this Mac has \(model.host.memoryGB) GB" } ?? "No requirement on file")
                    HStack {
                        Button("Add to Dock") { model.addToDock(game) }
                        Button("Show Files") { model.showInFinder(game) }
                        Button("Store Page") { model.openStorePage(game) }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Reset to Recommended") {
                    model.core.profiles.clearOverride(game.id)
                    launchOptions = current.gameArgs?.joined(separator: " ") ?? ""
                    Task { await model.refresh() }
                }
                Spacer()
                Button("Done") { saveLaunchOptions(); dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 540, height: 640)
        .onAppear { launchOptions = current.gameArgs?.joined(separator: " ") ?? "" }
    }

    private func saveLaunchOptions() {
        let args = launchOptions.split(separator: " ").map(String.init)
        guard args != (current.gameArgs ?? []) else { return }
        model.updateSettings(for: game) { $0.gameArgs = args }
    }

    private func binding<T>(_ key: WritableKeyPath<GameProfile, T?>) -> Binding<T?> {
        Binding(get: { override?[keyPath: key] }, set: { value in model.updateSettings(for: game) { $0[keyPath: key] = value } })
    }

    private func toggle(_ key: WritableKeyPath<GameProfile, Bool?>) -> Binding<Bool> {
        Binding(get: { current[keyPath: key] ?? false }, set: { on in model.updateSettings(for: game) { $0[keyPath: key] = on ? true : nil } })
    }
}

/// Selectable cards, after hilos' preference tiles on Mobbin.
struct PresetCard: View {
    let preset: GamePreset
    let selected: Bool
    let backend: GraphicsBackend
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: icon).font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                Text(preset.title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(selected ? 0.1 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Color.accentColor : .white.opacity(0.1), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var icon: String {
        switch preset {
        case .quality: "sparkles"
        case .balanced: "scale.3d"
        case .battery: "leaf.fill"
        }
    }

    private var detail: String {
        guard backend.supportsFrameCap else {
            return preset == .quality ? "Full speed" : "No cap on \(backend.shortName)"
        }
        return preset.frameCap == 0 ? "No frame limit" : "Limit to \(preset.frameCap) fps"
    }
}
