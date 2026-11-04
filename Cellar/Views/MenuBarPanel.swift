import AppKit
import CellarKit
import SwiftUI

/// What opens from Cellar's icon in the menu bar: the running game or recent ones, friends, music
/// and shortcuts, without opening Cellar's window.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let game = model.runningGame {
                running(game)
            } else if !model.installedGames.isEmpty {
                recent
            }
            friends
            if SpotifyPlayer.isRunning, model.spotify.hasTrack || model.spotifyPermission == .allowed {
                section("Music") { MiniPlayer() }
            }
            Divider().opacity(0.5)
            footer
        }
        .padding(14)
        .frame(width: 320)
        .preferredColorScheme(.dark)
        .task { await model.refreshMusic() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppMark(size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Wordmark(size: 16)
                HStack(spacing: 5) {
                    Circle().fill(model.steamStatus.color).frame(width: 7, height: 7)
                    Text("Steam: \(model.steamStatus.title)").font(.cCaption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Open") { showCellar() }
                .buttonStyle(GlassButtonStyle())
        }
    }

    private func running(_ game: Game) -> some View {
        section("Playing") {
            HStack(spacing: 10) {
                ArtworkImage(url: game.artwork?.capsule)
                    .frame(width: 34, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(game.name).font(.cCallout.weight(.semibold)).lineLimit(1)
                    if let start = model.sessionStarts[game.id] {
                        Text(AppModel.playTime(Date().timeIntervalSince(start))).font(.cCaption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                Button("Overlay") {
                    dismiss()
                    model.overlay.show()
                }
                .buttonStyle(GlassButtonStyle())
            }
        }
    }

    private var recent: some View {
        section("Jump back in") {
            VStack(spacing: 4) {
                ForEach(model.installedGames.prefix(4)) { game in
                    MenuBarGameRow(game: game) {
                        dismiss()
                        model.focusedGameID = game.id
                        model.play(game)
                    }
                }
            }
        }
    }

    @ViewBuilder private var friends: some View {
        let online = model.friendsInGame + model.friendsOnline
        if !online.isEmpty {
            section("Friends") {
                Button {
                    model.tab = .friends
                    showCellar()
                } label: {
                    HStack(spacing: 8) {
                        HStack(spacing: -6) {
                            ForEach(online.prefix(4)) { friend in
                                Avatar(friend: friend, size: 24)
                            }
                        }
                        Text(friendsLine).font(.cCaption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var friendsLine: String {
        let playing = model.friendsInGame.count
        let total = model.friendsInGame.count + model.friendsOnline.count
        return playing > 0 ? "\(total) online, \(playing) playing" : "\(total) online"
    }

    private var footer: some View {
        HStack(spacing: 12) {
            link("Steam") {
                dismiss()
                model.openSteam()
            }
            link("Clips") {
                dismiss()
                model.showClipsFolder()
            }
            link("Settings") {
                model.openSettings()
                showCellar()
            }
            Spacer()
            link("Quit Cellar") { NSApp.terminate(nil) }
        }
    }

    private func link(_ title: String, run: @escaping () -> Void) -> some View {
        Button(title, action: run).buttonStyle(.plain).font(.cCaption).foregroundStyle(.secondary)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(.cCaption2.weight(.bold)).tracking(1).foregroundStyle(.secondary)
            content()
        }
    }

    private func showCellar() {
        dismiss()
        openWindow(id: "main")
        NSApp.activate()
    }
}

struct MenuBarGameRow: View {
    @Environment(AppModel.self) private var model
    let game: Game
    let play: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: play) {
            HStack(spacing: 10) {
                ArtworkImage(url: game.artwork?.capsule)
                    .frame(width: 24, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text(game.name).font(.cCallout).lineLimit(1)
                Spacer(minLength: 4)
                if model.launching == game.id {
                    ProgressView().controlSize(.small)
                } else if hovering {
                    Image(systemName: "play.fill").font(.cCaption)
                }
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(hovering ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Play \(game.name)")
    }
}
