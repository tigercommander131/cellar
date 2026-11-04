import CellarKit
import SwiftUI

/// Settings, inside the app: a short list of categories, in plain words.
struct SettingsScreen: View {
    enum Category: String, CaseIterable, Identifiable {
        case general = "General", games = "Games", clips = "Clips and overlay", updates = "Updates", advanced = "Advanced"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: "gearshape.fill"
            case .games: "gamecontroller.fill"
            case .clips: "record.circle"
            case .updates: "arrow.down.circle.fill"
            case .advanced: "wrench.and.screwdriver.fill"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @FocusState private var sidebarFocused: Bool
    @AppStorage("overlayHotkey") private var hotkey = OverlayHotkey.shiftTab.rawValue
    @State private var category: Category = .general

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings").font(.cellar(28, .heavy)).padding(.bottom, 14)
                ForEach(Category.allCases) { item in
                    Button { category = item } label: {
                        Label {
                            Text(item.rawValue).font(.cellar(13.5, .semibold))
                        } icon: {
                            Image(systemName: item.icon).frame(width: 20)
                        }
                        .foregroundStyle(category == item ? .black : .white)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 12)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(category == item ? .white : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 214)
            .focusable()
            .focused($sidebarFocused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(-1) }
            .onKeyPress(.downArrow) { move(1) }
            .onAppear { sidebarFocused = true }
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

    private func move(_ delta: Int) -> KeyPress.Result {
        let all = Category.allCases
        guard let current = all.firstIndex(of: category) else { return .ignored }
        category = all[min(max(current + delta, 0), all.count - 1)]
        return .handled
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
            ToggleRow("Show Cellar in the menu bar", "Your games and music, one click away.", isOn: Binding(get: { model.menuBarIcon }, set: { model.setMenuBarIcon($0) }))
            ToggleRow("Find games in Spotlight", "Type a game's name to start it. Also lets you say \"Play Teardown in Cellar\" to Siri.", isOn: Binding(get: { model.gamesInSpotlight }, set: { model.setGamesInSpotlight($0) }))
        }
    }

    private var games: some View {
        Group {
            ToggleRow("Trailers on the Games screen", "Silent, and only while Cellar is in front and no game is running. Uses internet and some battery.", isOn: Binding(get: { model.trailersEnabled }, set: { model.setTrailersEnabled($0) }))
            ToggleRow("Hide Steam while playing", "Steam's window draws on the CPU, so keeping it closed saves CPU, memory and battery.", isOn: Binding(get: { model.hideSteamWhilePlaying }, set: { model.setHideSteamWhilePlaying($0) }))
            ToggleRow("Offer fixes for games that won't start", "If a game closes right after starting, Cellar asks whether to try another graphics option.", isOn: Binding(get: { model.selfFixGames }, set: { model.setSelfFixGames($0) }))
        }
    }

    private var clips: some View {
        Group {
            ToggleRow("Turn Clips on with every game", "Option+C saves a clip. Uses a little extra heat and battery, and stops when the game closes.", isOn: Binding(get: { model.autoClips }, set: { model.setAutoClips($0) }))
            SettingRow("Save the last", "How far back Option+C goes.") {
                Picker("Save the last", selection: Binding(get: { model.clipSeconds }, set: { model.setClipSeconds($0) })) {
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                }
                .labelsHidden().fixedSize()
            }
            SettingRow("Saved clips", "Watch, trim and share them in Clips. The files are in Movies › Cellar Clips.") {
                Button("Show in Finder") { model.showClipsFolder() }.buttonStyle(GlassButtonStyle())
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
            ToggleRow("Get beta versions", "New versions arrive first, and are less tested.", isOn: Binding(get: { model.betaUpdates }, set: { model.setBetaUpdates($0) }))
        }
    }

    private var advanced: some View {
        Group {
            ToggleRow("FPS counter in games", "Apple's performance overlay. Each game can override this.", isOn: Binding(get: { model.showFPS }, set: { model.setShowFPS($0) }))
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

/// A setting that's just on or off. Clicking anywhere on the row flips it.
struct ToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    init(_ title: String, _ detail: String, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        Button { isOn.toggle() } label: {
            SettingRow(title, detail) {
                Toggle(title, isOn: $isOn).toggleStyle(CellarToggleStyle()).allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
