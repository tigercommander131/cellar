import CellarKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Toggle("Low-memory mode", isOn: Binding(get: { model.lowMemoryMode }, set: { model.setLowMemoryMode($0) }))
                Text("Hides Steam's window while a game runs and keeps Steam's browser lighter. On by default for Macs with 8 GB of memory (this Mac: \(model.host.memoryGB) GB).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Steam") {
                Toggle("Offline mode", isOn: Binding(get: { model.steamOffline }, set: { model.setSteamOffline($0) }))
                Text("For Wi-Fi that blocks Steam, like school networks. Games start with the sign-in Steam saved last time you were online. Multiplayer, friends and downloads need it off. Steam restarts when you change this.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Performance") {
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
