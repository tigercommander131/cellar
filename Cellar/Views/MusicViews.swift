import CellarKit
import SwiftUI

/// Where the song has got to. Between readings it just keeps counting.
private func livePosition(_ state: SpotifyState, at date: Date) -> Double {
    let moved = state.isPlaying ? date.timeIntervalSince(state.updated) : 0
    return min(max(state.position + moved, 0), max(state.duration, 0))
}

private func clock(_ seconds: Double) -> String {
    let whole = Int(seconds)
    return String(format: "%d:%02d", whole / 60, whole % 60)
}

struct SpotifyCover: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "music.note").foregroundStyle(.white.opacity(0.4))
                }
            }
        }
    }
}

struct MusicButtons: View {
    @Environment(AppModel.self) private var model
    var size: CGFloat = 16

    var body: some View {
        HStack(spacing: size * 0.9) {
            button("backward.fill", "Previous song", size) { model.music(.previous) }
            button(model.spotify.isPlaying ? "pause.fill" : "play.fill", model.spotify.isPlaying ? "Pause" : "Play", size * 1.35) { model.music(.playPause) }
            button("forward.fill", "Next song", size) { model.music(.next) }
        }
    }

    private func button(_ icon: String, _ label: String, _ size: CGFloat, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size * 1.9, height: size * 1.9)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// What's needed before there's music to control, or nil once it's all set.
struct MusicSetupPrompt: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !SpotifyPlayer.isInstalled {
            prompt("Spotify isn't on this Mac", "Install the Spotify app, and Cellar can control it from here.", nil) {}
        } else {
            switch model.spotifyPermission {
            case .notRunning:
                prompt("Spotify isn't open", "Open it to control your music from here. Cellar won't start any music by itself.", "Open Spotify") { model.openSpotify() }
            case .wouldAsk:
                prompt("Connect Spotify", "macOS asks once whether Cellar can control Spotify. There's no sign-in, and Cellar never sees your account.", "Connect") { model.connectSpotify() }
            case .denied:
                prompt("Cellar can't control Spotify", "Turn on Spotify for Cellar in System Settings, under Automation.", "Open Settings") { model.openAutomationSettings() }
            case .allowed:
                EmptyView()
            }
        }
    }

    private func prompt(_ title: String, _ detail: String, _ button: String?, run: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note").font(.system(size: 40, weight: .light)).foregroundStyle(.white.opacity(0.4))
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            if let button {
                Button(button, action: run).buttonStyle(PillButtonStyle()).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

/// The overlay's Music tab.
struct OverlayMusicTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if !model.spotifyChecked {
                ProgressView().controlSize(.small)
            } else if model.spotifyPermission == .allowed {
                if model.spotify.hasTrack {
                    player
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "music.note").font(.system(size: 40, weight: .light)).foregroundStyle(.white.opacity(0.4))
                        Text("Nothing's playing").font(.headline)
                        MusicButtons(size: 22).environment(model)
                    }
                }
            } else {
                MusicSetupPrompt()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The cover goes in an overlay on something sized to this tab: as a background of its own, a square
        // image grew past the tab, over the tab bar, greying it out and taking its clicks.
        .background {
            Color.white.opacity(0.05)
                .overlay { SpotifyCover(url: model.spotify.artwork).blur(radius: 60).opacity(0.45) }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .allowsHitTesting(false)
        }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .task { await model.refreshMusic() }
    }

    private var player: some View {
        HStack(spacing: 40) {
            SpotifyCover(url: model.spotify.artwork)
                .frame(width: 300, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.spotify.name ?? "").font(.system(size: 30, weight: .heavy)).lineLimit(2)
                    Text(model.spotify.artist ?? "").font(.title3.weight(.medium)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    Text(model.spotify.album ?? "").font(.callout).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                SeekBar().environment(model)
                MusicButtons(size: 24).environment(model)
                MusicVolume().environment(model)
            }
            .frame(maxWidth: 480, alignment: .leading)
        }
        .padding(40)
    }
}

struct SeekBar: View {
    @Environment(AppModel.self) private var model
    @State private var dragging: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let state = model.spotify
            let shown = dragging ?? livePosition(state, at: context.date)
            VStack(spacing: 2) {
                Slider(value: Binding(get: { shown }, set: { dragging = $0 }), in: 0...max(state.duration, 1)) { editing in
                    if !editing, let target = dragging {
                        model.music(.seek(target))
                        dragging = nil
                    }
                }
                .controlSize(.small)
                .labelsHidden()
                HStack {
                    Text(clock(shown))
                    Spacer()
                    Text(clock(state.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}

struct MusicVolume: View {
    @Environment(AppModel.self) private var model
    @State private var level: Double?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.white.opacity(0.6))
            Slider(value: Binding(get: { level ?? Double(model.spotify.volume ?? 50) }, set: { level = $0 }), in: 0...100) { editing in
                if !editing, let target = level {
                    model.music(.volume(Int(target)))
                    level = nil
                }
            }
            .controlSize(.small)
            .labelsHidden()
            Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.white.opacity(0.6))
        }
        .help("Spotify's volume, separate from the game's")
    }
}

/// One row for the overlay's Home tab and the menu bar.
struct MiniPlayer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            SpotifyCover(url: model.spotify.artwork)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(model.spotify.name ?? "Spotify").font(.callout.weight(.semibold)).lineLimit(1)
                Text(model.spotify.artist ?? (model.spotify.isPlaying ? "" : "Paused")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            MusicButtons(size: 12)
        }
    }
}
