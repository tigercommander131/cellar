import CellarKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("overlayHotkey") private var hotkey = OverlayHotkey.shiftTab.rawValue

    var body: some View {
        Form {
            Section("Steam") {
                Picker("Connection", selection: Binding(get: { model.connectionMode }, set: { model.setConnectionMode($0) })) {
                    Text("Automatic").tag(ConnectionMode.automatic)
                    Text("Always online").tag(ConnectionMode.online)
                    Text("Always offline").tag(ConnectionMode.offline)
                }
                LabeledContent("Right now", value: model.steamStatus.title)
                Text("Automatic checks whether Steam can really connect, whenever your network changes. On Wi-Fi that blocks Steam, like at school, it goes offline by itself, and games start with the sign-in Steam saved last time. If a game is running, the switch waits until it closes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Overlay") {
                Picker("Open Cellar's overlay with", selection: $hotkey) {
                    ForEach(OverlayHotkey.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Text("Works while a game is running: friends, clips, performance, notes and quitting, over any game.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Clips") {
                Picker("Save the last", selection: Binding(get: { model.clipSeconds }, set: { model.setClipSeconds($0) })) {
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                }
                HStack {
                    Text("Turn Clips on in the overlay. They stop when the game closes.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show Clips") { model.showClipsFolder() }
                }
            }
            Section("Games") {
                Toggle("Fix games that won't start", isOn: Binding(get: { model.selfFixGames }, set: { model.setSelfFixGames($0) }))
                Text("If a game closes right after starting, Cellar tries the other graphics options and keeps the one that works. A graphics option you picked yourself is left alone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Menu bar and updates") {
                Toggle("Show Cellar in the menu bar", isOn: Binding(get: { model.menuBarIcon }, set: { model.setMenuBarIcon($0) }))
                LabeledContent("Cellar \(appVersion)") {
                    Button("Check for Updates…") { model.checkForUpdates?() }
                }
                Toggle("Get beta versions of Cellar", isOn: Binding(get: { model.betaUpdates }, set: { model.setBetaUpdates($0) }))
                Text("Beta versions arrive first and are less tested.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Spotlight and Siri") {
                Toggle("Find games in Spotlight", isOn: Binding(get: { model.gamesInSpotlight }, set: { model.setGamesInSpotlight($0) }))
                Text("Keeps a small launcher for each installed game in Applications › Cellar Games, so typing its name in Spotlight starts it. Also lets you say \"Play Teardown in Cellar\" to Siri.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Performance") {
                Toggle("Hide Steam while playing", isOn: Binding(get: { model.hideSteamWhilePlaying }, set: { model.setHideSteamWhilePlaying($0) }))
                Text("Steam's window draws on the CPU, so keeping it closed frees CPU, memory and battery.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show FPS counter in games", isOn: Binding(get: { model.showFPS }, set: { model.setShowFPS($0) }))
                Text("Apple's Metal overlay: frame rate, frame time and GPU use. Each game can override this in its settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Installed components") {
                ForEach(PackKind.allCases, id: \.self) { kind in
                    LabeledContent(kind.label, value: model.core.packs.installed(kind)?.version ?? "Not installed")
                }
            }
            Section("Troubleshooting") {
                HStack {
                    Button("Show Logs") { model.openLogs() }
                    Button("Show Cellar Folder") { NSWorkspace.shared.open(model.core.paths.root) }
                    Spacer()
                    Button("Force Quit All Games", role: .destructive) { model.stopAll() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
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
