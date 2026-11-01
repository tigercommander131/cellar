import CellarKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("overlayHotkey") private var hotkey = OverlayHotkey.shiftTab.rawValue

    var body: some View {
        Form {
            Section("Steam") {
                Toggle("Offline mode", isOn: Binding(get: { model.steamOffline }, set: { model.setSteamOffline($0) }))
                Text("For Wi-Fi that blocks Steam, like school networks. Games start with the sign-in Steam saved last time you were online. Multiplayer, friends and downloads need it off. Steam restarts when you change this.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Overlay") {
                Picker("Open Cellar's overlay with", selection: $hotkey) {
                    ForEach(OverlayHotkey.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Text("Works while a game is running. Friends, Join, Invite and Force Quit, over any game.")
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
