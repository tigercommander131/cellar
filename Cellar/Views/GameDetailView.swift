import CellarKit
import SwiftUI

/// A game's own screen: how it should run, what to set inside it, and the rest out of the way.
struct GameScreen: View {
    @Environment(AppModel.self) private var model
    let game: Game
    @State private var showAdvanced = false
    @State private var launchOptions = ""

    private var override: GameProfile? { model.core.profiles.override(game.id) }
    private var recommended: GraphicsBackend { model.core.profiles.builtIn(game.id)?.graphics ?? .d3dmetal }
    /// Live values: `game` is a snapshot from when the screen opened.
    private var current: GameProfile { model.core.profiles.profile(for: game.id) }

    var body: some View {
        ZStack {
            Theme.ground
            Color.clear
                .overlay { ArtworkImage(url: game.artwork?.hero ?? game.artwork?.header) }
                .blur(radius: 26)
                .saturation(1.1)
                .opacity(0.38)
                .clipped()
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 14) {
                    ArtworkImage(url: game.artwork?.capsule, fallbackTitle: game.name)
                        .frame(width: 210, height: 315)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    Text(game.name).font(.cellar(24, .heavy)).lineLimit(3).frame(width: 240, alignment: .leading)
                    if let specs = model.macSpecs {
                        Text(specs.summary).font(.cCaption).foregroundStyle(.white.opacity(0.78)).frame(width: 240, alignment: .leading)
                    }
                    Button("Done") { close() }
                        .buttonStyle(PillButtonStyle())
                        .keyboardShortcut(.cancelAction)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        presets
                        if let assessment = model.verdicts[game.id] { GameCard { VerdictDetails(gameID: game.id, assessment: assessment) } }
                        GameCard { RecommendedSettingsView(game: game, showsPreset: false) }
                        advanced
                    }
                    .padding(.vertical, 2)
                    .padding(.trailing, 8)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.horizontal, 44)
            .padding(.top, 58)
            .padding(.bottom, 24)
        }
        .ignoresSafeArea()
        .onAppear { launchOptions = current.gameArgs?.joined(separator: " ") ?? "" }
    }

    private func close() {
        saveLaunchOptions()
        model.settingsGame = nil
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How should it run?").font(.cHeadline)
            HStack(spacing: 12) {
                ForEach(GamePreset.allCases) { preset in
                    PresetCard(preset: preset, selected: (current.preset ?? .quality) == preset, backend: current.backend,
                               recommended: model.settingsAdvice[game.id]?.preset == preset) {
                        model.updateSettings(for: game) { $0.preset = preset; $0.frameCap = nil }
                    }
                }
            }
            if !current.backend.supportsFrameCap {
                Text("\(current.backend.shortName) can't limit frame rate from Cellar. Use vsync or the frame limit in the game's own settings to save power.")
                    .font(.cCaption).foregroundStyle(.white.opacity(0.78)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { showAdvanced.toggle() }
            } label: {
                Label(showAdvanced ? "Hide advanced options" : "Show advanced options", systemImage: showAdvanced ? "chevron.up" : "chevron.down")
                    .font(.cellar(13, .semibold))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showAdvanced {
                GameCard {
                    VStack(spacing: 0) {
                        SettingRow("Graphics", "Only change this if a game won't run or draws wrongly.") {
                            Picker("Graphics", selection: binding(\.graphics)) {
                                Text("Recommended (\(recommended.shortName))").tag(GraphicsBackend?.none)
                                Divider()
                                ForEach(GraphicsBackend.allCases, id: \.self) { Text($0.displayName).tag(GraphicsBackend?.some($0)) }
                            }
                            .labelsHidden().fixedSize()
                        }
                        SettingRow("Frame limit", "Overrides the preset's limit.") {
                            Picker("Frame limit", selection: binding(\.frameCap)) {
                                Text("From preset").tag(Int?.none)
                                Text("None").tag(Int?.some(0))
                                ForEach([30, 40, 60, 120], id: \.self) { Text("\($0) fps").tag(Int?.some($0)) }
                            }
                            .labelsHidden().fixedSize()
                            .disabled(!current.backend.supportsFrameCap)
                        }
                        SettingRow("FPS counter", "Apple's performance overlay.") {
                            Picker("FPS counter", selection: binding(\.metalHUD)) {
                                Text("Default (\(model.showFPS ? "on" : "off"))").tag(Bool?.none)
                                Text("On").tag(Bool?.some(true))
                                Text("Off").tag(Bool?.some(false))
                            }
                            .labelsHidden().fixedSize()
                        }
                        SettingRow("Retina resolution", "Sharper, but slower.") {
                            Toggle("Retina resolution", isOn: toggle(\.retina)).toggleStyle(CellarToggleStyle()).labelsHidden()
                        }
                        SettingRow("Steam overlay", "Experimental, and can crash some games. Only needed for a game's own Invite button.") {
                            Toggle("Steam overlay", isOn: toggle(\.steamOverlay)).toggleStyle(CellarToggleStyle()).labelsHidden()
                        }
                        SettingRow("Launch options", "For example, -novid") {
                            TextField("Launch options", text: $launchOptions, prompt: Text("None"))
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                                .frame(width: 180)
                                .onSubmit(saveLaunchOptions)
                        }
                        if let notes = current.notes {
                            SettingRow("Notes", notes) { EmptyView() }
                        }
                    }
                }
                HStack(spacing: 8) {
                    Button("Add to Dock") { model.addToDock(game) }
                    Button("Show Files") { model.showInFinder(game) }
                    Button("Store Page") { model.openStorePage(game) }
                    Spacer()
                    Button("Reset to Recommended") {
                        model.core.profiles.clearOverride(game.id)
                        launchOptions = current.gameArgs?.joined(separator: " ") ?? ""
                        Task { await model.refresh() }
                    }
                }
                .buttonStyle(GlassButtonStyle())
                Text("\(game.app.sizeOnDisk.formattedBytes). Steam app ID \(game.id). Changes apply the next time you press Play, and Steam restarts if needed.")
                    .font(.cCaption).foregroundStyle(.white.opacity(0.72)).fixedSize(horizontal: false, vertical: true)
            }
        }
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

struct GameCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.black.opacity(0.42)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
    }
}

/// A choice of how a game runs. White when it's the one in use.
struct PresetCard: View {
    let preset: GamePreset
    let selected: Bool
    let backend: GraphicsBackend
    var recommended = false
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 4) {
                Text(preset.title).font(.cellar(15, .bold))
                Text(recommended ? "Recommended for this Mac" : detail).font(.cCaption).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .padding(14)
            .foregroundStyle(selected ? .black : .white)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(selected ? .white : .black.opacity(0.42)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected ? .clear : Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var detail: String {
        guard backend.supportsFrameCap else {
            return preset == .quality ? "Full speed" : "No frame limit on \(backend.shortName)"
        }
        return preset.frameCap == 0 ? "Full speed" : "Limit to \(preset.frameCap) fps"
    }
}
