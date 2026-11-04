import CellarKit
import SwiftUI

/// The top bar's account button: says what Steam is doing, and has everything Steam-related one click
/// away. Online or offline is automatic, so that choice is tucked underneath.
struct SteamButton: View {
    @Environment(AppModel.self) private var model
    @State private var open = false

    var body: some View {
        let status = model.steamStatus
        Button { open.toggle() } label: {
            HStack(spacing: 7) {
                if model.switchingConnection {
                    ProgressView().controlSize(.mini).tint(.white)
                } else {
                    Circle().fill(status.color).frame(width: 8, height: 8)
                }
                Text(model.steamUser ?? "Steam")
                    .font(.cellar(12.5, .semibold))
                if model.steamOffline || model.switchingConnection {
                    Text(status.title).foregroundStyle(status.color)
                }
            }
        }
        .buttonStyle(GlassButtonStyle())
        .fixedSize()
        .help("Steam: \(status.title)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            SteamMenu { open = false }
                .environment(model)
                .preferredColorScheme(.dark)
        }
    }
}

struct SteamMenu: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void

    var body: some View {
        let status = model.steamStatus
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white.opacity(0.75))
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.steamUser ?? "Not signed in").font(.cHeadline).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(status.color).frame(width: 7, height: 7)
                        Text(status.title).font(.cCaption.weight(.semibold)).foregroundStyle(status.color)
                    }
                }
                Spacer()
            }
            Text(status.detail)
                .font(.cCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    page("Library", "books.vertical.fill", .library)
                    page("Store", "storefront.fill", .store)
                }
                GridRow {
                    page("Downloads", "arrow.down.circle.fill", .downloads)
                    page("Friends", "person.2.fill", .friends)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("CONNECTION").font(.cCaption2.weight(.bold)).tracking(1).foregroundStyle(.secondary)
                Picker("Connection", selection: Binding(get: { model.connectionMode }, set: { model.setConnectionMode($0) })) {
                    ForEach(ConnectionMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if model.steamRunning {
                HStack {
                    Button("Restart Steam") { close(); model.restartSteam() }
                    Button("Quit Steam") { close(); model.quitSteam() }
                }
                .buttonStyle(.link)
                .font(.cCaption)
                .disabled(model.runningGame != nil || model.switchingConnection)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func page(_ title: String, _ icon: String, _ page: AppModel.SteamPage) -> some View {
        Button {
            close()
            model.openSteamPage(page)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 16))
                Text(title).font(.cCaption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
