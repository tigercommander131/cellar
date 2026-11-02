import AppKit
import CellarKit
import Foundation

/// Spotify on this Mac. Cellar only ever does what the player presses, and never starts music by itself.
extension AppModel {
    func startMusicWatch() {
        guard spotifyWatcher == nil else { return }
        spotifyWatcher = SpotifyWatcher { state in
            AppModel.shared.spotifyChanged(state)
        }
    }

    private func spotifyChanged(_ new: SpotifyState) {
        let changedTrack = new.trackID != spotify.trackID
        var merged = new
        merged.volume = spotify.volume
        merged.artwork = changedTrack ? nil : spotify.artwork
        spotify = merged
        guard changedTrack else { return }
        if new.isPlaying, new.hasTrack, runningGame != nil, !overlay.isVisible {
            let line = [new.name, new.artist].compactMap { $0 }.joined(separator: " · ")
            overlay.showHUD(line, systemImage: "music.note")
        }
        if overlay.isVisible || spotifyPermission == .allowed { Task { await refreshMusic() } }
    }

    /// Asks the app for cover art, volume and position. Never shows macOS's permission question.
    func refreshMusic() async {
        let (permission, state) = await Task.detached { () -> (SpotifyPlayer.Permission, SpotifyState?) in
            let permission = SpotifyPlayer.permission()
            return (permission, permission == .allowed ? (try? SpotifyPlayer.read()) ?? nil : nil)
        }.value
        spotifyPermission = permission
        if let state { spotify = state }
        if permission == .notRunning { spotify = SpotifyState() }
    }

    /// Keeps the position current only while someone can see it.
    func startMusicPolling() {
        musicTask?.cancel()
        musicTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshMusic()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stopMusicPolling() {
        musicTask?.cancel()
        musicTask = nil
    }

    func music(_ command: SpotifyPlayer.Command) {
        guard spotifyPermission == .allowed else { return connectSpotify() }
        Task {
            await Task.detached { try? SpotifyPlayer.send(command) }.value
            // Spotify takes a moment to act on a command.
            try? await Task.sleep(for: .milliseconds(250))
            await refreshMusic()
        }
    }

    /// macOS draws its question under the overlay, so the overlay gets out of the way first.
    func connectSpotify() {
        if spotifyPermission == .denied { return openAutomationSettings() }
        overlay.hide()
        Task {
            let permission = await Task.detached { SpotifyPlayer.permission(ask: true) }.value
            spotifyPermission = permission
            if permission == .allowed {
                overlay.showHUD("Spotify connected", systemImage: "music.note")
            }
            await refreshMusic()
        }
    }

    func openAutomationSettings() {
        overlay.hide()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    func openSpotify() {
        overlay.hide()
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyPlayer.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
