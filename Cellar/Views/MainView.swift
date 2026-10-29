import CellarKit
import SwiftUI

enum SidebarItem: Hashable {
    case library
    case downloads
    case game(String)
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .library

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("Library", systemImage: "square.grid.2x2").tag(SidebarItem.library)
                    Label("Downloads", systemImage: "arrow.down.circle")
                        .badge(model.downloadingGames.count)
                        .tag(SidebarItem.downloads)
                }
                if !model.installedGames.isEmpty {
                    Section("Games") {
                        ForEach(model.installedGames) { game in
                            HStack(spacing: 8) {
                                ArtworkImage(url: game.artwork?.header)
                                    .frame(width: 34, height: 16)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                                Text(game.name).lineLimit(1)
                                Spacer()
                                if game.isRunning { StatusDot(on: true) }
                            }
                            .tag(SidebarItem.game(game.id))
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .safeAreaInset(edge: .bottom) { SteamStatusBar() }
        } detail: {
            switch selection {
            case .game(let id):
                if let game = model.games.first(where: { $0.id == id }) {
                    GameDetailView(game: game)
                } else {
                    LibraryView(selection: $selection)
                }
            case .downloads:
                DownloadsView()
            default:
                LibraryView(selection: $selection)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.runningGame != nil || model.launching != nil {
                    Button { model.stopAll() } label: { Label("Force Quit", systemImage: "stop.fill") }
                        .help("Force-quit Steam and every game (⇧⌘K)")
                }
                Button { model.openSteam() } label: { Label("Open Steam", systemImage: "storefront") }
                    .help("Open Steam to browse the store or install games")
            }
        }
    }
}

/// Steam's state at the bottom of the sidebar.
struct SteamStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(on: model.steamRunning)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.steamRunning ? "Steam is running" : "Steam is closed").font(.callout)
                if let user = model.steamUser {
                    Text(user).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Not signed in").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.lowMemoryMode {
                Image(systemName: "memorychip")
                    .foregroundStyle(.secondary)
                    .help("Low-memory mode is on")
            }
        }
        .padding(12)
    }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 22)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Library").font(.system(size: 30, weight: .bold))
                Text(countText).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 24)

            if model.installedGames.isEmpty {
                EmptyLibrary()
                    .padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                    ForEach(model.installedGames) { game in
                        GameCard(game: game) { selection = .game(game.id) }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 22)
            }
        }
    }

    private var countText: String {
        let n = model.installedGames.count
        return n == 1 ? "1 game installed" : "\(n) games installed"
    }
}

struct EmptyLibrary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("No games yet").font(.title2.weight(.semibold))
            Text(model.steamUser == nil
                 ? "Open Steam and sign in. Games you install there show up here."
                 : "Open Steam and install a game. It shows up here when it's ready.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("Open Steam") { model.openSteam() }
                .buttonStyle(PillButtonStyle())
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Portrait cover with a Play pill on hover.
struct GameCard: View {
    @Environment(AppModel.self) private var model
    let game: Game
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkImage(url: game.artwork?.capsule, fallbackTitle: game.name)
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottom) {
                    if hovering || game.isRunning || model.launching == game.id {
                        playOverlay.padding(12).transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(hovering ? 0.35 : 0.08))
                }
                .shadow(color: .black.opacity(hovering ? 0.45 : 0.25), radius: hovering ? 14 : 6, y: hovering ? 8 : 3)
                .scaleEffect(hovering ? 1.03 : 1)
            Text(game.name).font(.headline).lineLimit(1)
            Text(status).font(.caption).foregroundStyle(game.isRunning ? .green : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { h in withAnimation(.snappy(duration: 0.18)) { hovering = h } }
        .contextMenu {
            Button("Play") { model.play(game) }
            Button("Show in Finder") { model.showInFinder(game) }
            Button("Store Page") { model.openStorePage(game) }
        }
    }

    @ViewBuilder private var playOverlay: some View {
        if game.isRunning {
            Label("Running", systemImage: "play.circle.fill")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(.green.opacity(0.85)))
        } else if model.launching == game.id {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Starting…") }
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(.black.opacity(0.7)))
        } else {
            Button { model.play(game) } label: { Label("Play", systemImage: "play.fill") }
                .buttonStyle(PillButtonStyle())
        }
    }

    private var status: String {
        if game.isRunning { return "Running" }
        return game.profile.backend.shortName
    }
}

struct DownloadsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Downloads").font(.system(size: 30, weight: .bold))
                Text("Games install through Steam. Keep Steam open until they finish.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32).padding(.top, 24)

            VStack(spacing: 12) {
                if model.downloadingGames.isEmpty {
                    Text("Nothing downloading.").foregroundStyle(.secondary).padding(.top, 40)
                }
                ForEach(model.downloadingGames) { game in
                    HStack(spacing: 14) {
                        ArtworkImage(url: game.artwork?.header)
                            .frame(width: 120, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(game.name).font(.headline)
                            if let p = game.app.downloadProgress {
                                ProgressView(value: p).tint(.accentColor)
                                Text("\(game.app.bytesDownloaded.formattedBytes) of \(game.app.bytesToDownload.formattedBytes)")
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            } else {
                                Text(game.app.isUpdating ? "Updating…" : "Waiting in Steam's queue").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 20)
        }
    }
}
