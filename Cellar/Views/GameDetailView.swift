import CellarKit
import SwiftUI

/// A game's page: hero art with Play, then its settings.
struct GameDetailView: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        ScrollView {
            hero
            VStack(alignment: .leading, spacing: 28) {
                settings
                about
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .ignoresSafeArea(edges: .top)
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            // A fill image must not report its own (huge) size, or it squeezes the sidebar shut.
            Color.clear
                .frame(height: 340)
                .frame(maxWidth: .infinity)
                .overlay { ArtworkImage(url: game.artwork?.hero ?? game.artwork?.header, fallbackTitle: "") }
                .clipped()
            LinearGradient(stops: [
                .init(color: .clear, location: 0.35),
                .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.85), location: 0.85),
                .init(color: Color(nsColor: .windowBackgroundColor), location: 1),
            ], startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 16) {
                logo
                HStack(spacing: 12) {
                    playButton
                    CircleIconButton(systemImage: "bag", help: "Steam store page") { model.openStorePage(game) }
                    CircleIconButton(systemImage: "folder", help: "Show game files in Finder") { model.showInFinder(game) }
                }
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 24)
        }
        .frame(height: 340)
    }

    @ViewBuilder private var logo: some View {
        AsyncImage(url: game.artwork?.logo) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFit().frame(maxWidth: 320, maxHeight: 110, alignment: .leading)
                    .shadow(color: .black.opacity(0.5), radius: 8)
            } else {
                Text(game.name).font(.system(size: 38, weight: .heavy)).shadow(color: .black.opacity(0.5), radius: 8)
            }
        }
    }

    @ViewBuilder private var playButton: some View {
        if game.isRunning {
            Button { model.stopAll() } label: { Label("Stop", systemImage: "stop.fill") }
                .buttonStyle(PillButtonStyle(large: true))
                .tint(.gray)
        } else if model.launching == game.id {
            HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Starting…") }
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 24).padding(.vertical, 11)
                .background(Capsule().fill(.white.opacity(0.12)))
        } else {
            Button { model.play(game) } label: { Label("Play", systemImage: "play.fill") }
                .buttonStyle(PillButtonStyle(large: true))
                .keyboardShortcut(.defaultAction)
        }
    }

    private var override: GameProfile? { model.core.profiles.override(game.id) }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.title2.weight(.semibold))
            VStack(spacing: 0) {
                row("Graphics") {
                    Picker("", selection: Binding(
                        get: { override?.graphics },
                        set: { model.setBackend($0, for: game) }
                    )) {
                        Text("Recommended (\(model.core.profiles.builtIn(game.id)?.graphics?.shortName ?? GraphicsBackend.d3dmetal.shortName))").tag(GraphicsBackend?.none)
                        Divider()
                        ForEach(GraphicsBackend.allCases, id: \.self) { b in
                            Text(b.displayName).tag(GraphicsBackend?.some(b))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                }
                Divider().opacity(0.4)
                row("Memory") {
                    Text(game.profile.minRAMGB.map { "Wants \($0) GB · this Mac has \(model.host.memoryGB) GB" } ?? "No requirement on file")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
            if let notes = game.profile.notes {
                Label(notes, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("Changes apply the next time you press Play. Steam restarts if it needs different settings.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About").font(.title2.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow { Text("Size").foregroundStyle(.secondary); Text(game.app.sizeOnDisk.formattedBytes) }
                GridRow { Text("Steam app ID").foregroundStyle(.secondary); Text(game.id).textSelection(.enabled) }
                GridRow { Text("Folder").foregroundStyle(.secondary); Text(game.app.installDir).lineLimit(1) }
            }
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
            Spacer()
            content()
        }
        .padding(.vertical, 12)
    }
}
