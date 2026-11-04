import CellarKit
import SwiftUI

/// Settings, inside the app: a short list of categories, in plain words.
struct SettingsScreen: View {
    enum Category: String, CaseIterable, Identifiable {
        case general = "General", games = "Games", clips = "Clips and overlay", updates = "Updates", advanced = "Advanced"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @AppStorage("overlayHotkey") private var hotkey = OverlayHotkey.shiftTab.rawValue
    @State private var category: Category = .general

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings").font(.cellar(28, .heavy)).padding(.bottom, 14)
                ForEach(Category.allCases) { item in
                    Button { category = item } label: {
                        Text(item.rawValue)
                            .font(.cellar(13.5, .semibold))
                            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                            .padding(.horizontal, 12)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(category == item ? .white.opacity(0.13) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 200)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(category.rawValue).font(.cellar(21, .bold)).padding(.bottom, 4)
                    content
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.trailing, 8)
                .padding(.top, 6)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 44)
        .padding(.top, 16)
    }

    @ViewBuilder private var content: some View {
        switch category {
        case .general: general
        case .games: games
        case .clips: clips
        case .updates: updates
        case .advanced: advanced
        }
    }

    private var general: some View {
        Group {
            SettingRow("Steam connection", "Goes offline by itself on Wi-Fi that blocks Steam, and back online when it can. Right now: \(model.steamStatus.title).") {
                Picker("Steam connection", selection: Binding(get: { model.connectionMode }, set: { model.setConnectionMode($0) })) {
                    Text("Automatic").tag(ConnectionMode.automatic)
                    Text("Always online").tag(ConnectionMode.online)
                    Text("Always offline").tag(ConnectionMode.offline)
                }
                .labelsHidden().fixedSize()
            }
            SettingRow("Show Cellar in the menu bar", "Your games and music, one click away.") {
                settingToggle("Show Cellar in the menu bar", Binding(get: { model.menuBarIcon }, set: { model.setMenuBarIcon($0) }))
            }
            SettingRow("Find games in Spotlight", "Type a game's name to start it. Also lets you say \"Play Teardown in Cellar\" to Siri.") {
                settingToggle("Find games in Spotlight", Binding(get: { model.gamesInSpotlight }, set: { model.setGamesInSpotlight($0) }))
            }
        }
    }

    private var games: some View {
        Group {
            SettingRow("Trailers on the Games screen", "Silent, and only while Cellar is in front and no game is running. Uses internet and some battery.") {
                settingToggle("Trailers on the Games screen", Binding(get: { model.trailersEnabled }, set: { model.setTrailersEnabled($0) }))
            }
            SettingRow("Hide Steam while playing", "Steam's window draws on the CPU, so keeping it closed saves CPU, memory and battery.") {
                settingToggle("Hide Steam while playing", Binding(get: { model.hideSteamWhilePlaying }, set: { model.setHideSteamWhilePlaying($0) }))
            }
            SettingRow("Offer fixes for games that won't start", "If a game closes right after starting, Cellar asks whether to try another graphics option.") {
                settingToggle("Offer fixes for games that won't start", Binding(get: { model.selfFixGames }, set: { model.setSelfFixGames($0) }))
            }
        }
    }

    private var clips: some View {
        Group {
            SettingRow("Turn Clips on with every game", "Option+C saves a clip. Uses a little extra heat and battery, and stops when the game closes.") {
                settingToggle("Turn Clips on with every game", Binding(get: { model.autoClips }, set: { model.setAutoClips($0) }))
            }
            SettingRow("Save the last", "How far back Option+C goes.") {
                Picker("Save the last", selection: Binding(get: { model.clipSeconds }, set: { model.setClipSeconds($0) })) {
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                }
                .labelsHidden().fixedSize()
            }
            SettingRow("Saved clips", "In Movies, in Cellar Clips.") {
                Button("Show Clips") { model.showClipsFolder() }.buttonStyle(GlassButtonStyle())
            }
            SettingRow("Open the overlay with", "Works during a game.") {
                Picker("Open the overlay with", selection: $hotkey) {
                    ForEach(OverlayHotkey.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .labelsHidden().fixedSize()
            }
        }
    }

    private var updates: some View {
        Group {
            SettingRow("Cellar \(appVersion)", "Cellar checks by itself, and game fixes arrive automatically.") {
                Button("Check for Updates…") { model.checkForUpdates?() }.buttonStyle(GlassButtonStyle())
            }
            SettingRow("Get beta versions", "New versions arrive first, and are less tested.") {
                settingToggle("Get beta versions", Binding(get: { model.betaUpdates }, set: { model.setBetaUpdates($0) }))
            }
        }
    }

    private var advanced: some View {
        Group {
            SettingRow("FPS counter in games", "Apple's performance overlay. Each game can override this.") {
                settingToggle("FPS counter in games", Binding(get: { model.showFPS }, set: { model.setShowFPS($0) }))
            }
            ForEach(PackKind.allCases, id: \.self) { kind in
                SettingRow(kind.label, model.core.packs.installed(kind)?.version ?? "Not installed") { EmptyView() }
            }
            SettingRow("Troubleshooting", "Logs and Cellar's own folder.") {
                HStack(spacing: 8) {
                    Button("Show Logs") { model.openLogs() }
                    Button("Show Folder") { NSWorkspace.shared.open(model.core.paths.root) }
                }
                .buttonStyle(GlassButtonStyle())
            }
            SettingRow("Force quit all games", "Closes Steam and every game. Anything unsaved is lost.") {
                Button("Force Quit") { model.stopAll() }.buttonStyle(GlassButtonStyle())
            }
        }
    }

    private func settingToggle(_ label: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn).toggleStyle(CellarToggleStyle()).labelsHidden()
    }
}

/// One setting: what it is on the left, the control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var control: Control

    init(_ title: String, _ detail: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.cellar(14, .semibold))
                Text(detail).font(.cCaption).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

private var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
}

extension PackKind {
    var label: String {
        switch self {
        case .engine: "Wine engine"
        case .dxmt: "DXMT"
        case .d3dmetal: "D3DMetal"
        case .profiles: "Game fixes"
        }
    }
}
