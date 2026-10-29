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
