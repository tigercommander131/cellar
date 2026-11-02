import AppKit
import CellarKit
import CoreGraphics
import Foundation

/// Clips are off until turned on for a session, and stop with the game.
extension AppModel {
    private var ownBundleID: String? { Bundle.main.bundleIdentifier }

    func setClipsRecording(_ on: Bool) {
        if on {
            startClips()
        } else {
            stopClips()
        }
    }

    /// The display the game (and so the overlay) is on.
    private var gameDisplay: CGDirectDisplayID? {
        (NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    private func startClips() {
        guard clipRecorder == nil, !clipsStarting else { return }
        // Asking ScreenCaptureKit would pop macOS's question up underneath the overlay.
        guard CGPreflightScreenCaptureAccess() else { return askForScreenRecording() }
        clipsStarting = true
        clipError = nil
        var options = ClipRecorder.Options()
        options.seconds = Double(clipSeconds)
        options.excludedBundleID = ownBundleID
        let recorder = ClipRecorder(options: options)
        let display = gameDisplay
        Task {
            defer { clipsStarting = false }
            do {
                try await recorder.start(display: display) { [weak self] error in
                    Task { @MainActor in
                        self?.stopClips()
                        self?.clipError = error.map { "Recording stopped: \($0.localizedDescription)" }
                    }
                }
                clipRecorder = recorder
                clipsRecording = true
                clipsNeedPermission = false
                overlay.setClipHotkeyActive(true)
                watchFrontmostApp()
                overlay.showHUD("Clips on. \(OverlayController.clipHotkeyLabel) saves the last \(clipLengthLabel).", systemImage: "record.circle")
            } catch {
                clipError = error.localizedDescription
            }
        }
    }

    private func stopClips() {
        guard let recorder = clipRecorder else { return }
        clipRecorder = nil
        clipsRecording = false
        overlay.setClipHotkeyActive(false)
        if let frontmostObserver { NSWorkspace.shared.notificationCenter.removeObserver(frontmostObserver) }
        frontmostObserver = nil
        Task { await recorder.stop() }
    }

    /// macOS draws its question under the overlay, so the overlay has to get out of the way.
    func askForScreenRecording() {
        clipsNeedPermission = true
        overlay.hide()
        CGRequestScreenCaptureAccess()
    }

    func openScreenRecordingSettings() {
        overlay.hide()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Only the game gets recorded: frames are dropped while some other Mac app is in front.
    private func watchFrontmostApp() {
        frontmostObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateCaptureGate() }
        }
        updateCaptureGate()
    }

    private func updateCaptureGate() {
        guard let recorder = clipRecorder, let front = NSWorkspace.shared.frontmostApplication else { return }
        if front.bundleIdentifier == ownBundleID {
            recorder.setCapturing(true)
            return
        }
        let core = self.core
        let pid = front.processIdentifier
        Task.detached {
            recorder.setCapturing(core.runningProcesses().contains { $0.pid == pid })
        }
    }

    func saveClip() {
        guard let recorder = clipRecorder else {
            overlay.showHUD("Clips are off. Turn them on in the overlay.", systemImage: "record.circle")
            return
        }
        guard !savingClip else { return }
        savingClip = true
        let url = ClipLibrary.newURL(game: runningGame?.name ?? "Game", kind: .video)
        Task {
            defer { savingClip = false }
            do {
                try await recorder.save(to: url)
                refreshClips()
                overlay.showHUD("Clip saved", systemImage: "checkmark.circle.fill")
            } catch {
                overlay.showHUD(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
            }
        }
    }

    /// A still of the game, taken from behind the overlay.
    func takeScreenshot() {
        guard CGPreflightScreenCaptureAccess() else { return askForScreenRecording() }
        let url = ClipLibrary.newURL(game: runningGame?.name ?? "Game", kind: .screenshot)
        let excluded = ownBundleID
        let display = gameDisplay
        Task {
            do {
                try await ClipRecorder.screenshot(to: url, excludedBundleID: excluded, display: display)
                refreshClips()
                overlay.showHUD("Screenshot saved", systemImage: "camera.fill")
            } catch {
                overlay.showHUD(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
            }
        }
    }

    func setAutoClips(_ on: Bool) {
        autoClips = on
        var state = core.loadState()
        state.autoClips = on ? nil : false
        try? core.saveState(state)
    }

    /// Called when a game starts. Without permission it stays quiet: macOS's question shouldn't
    /// pop up over a game that's starting, so that's asked when Clips are first switched on by hand.
    func startClipsForGame() {
        guard autoClips, CGPreflightScreenCaptureAccess() else { return }
        setClipsRecording(true)
    }

    func setClipSeconds(_ seconds: Int) {
        clipSeconds = seconds
        var state = core.loadState()
        state.clipSeconds = seconds == 30 ? nil : seconds
        try? core.saveState(state)
        if clipsRecording {
            stopClips()
            startClips()
        }
    }

    var clipLengthLabel: String {
        clipSeconds < 60 ? "\(clipSeconds) seconds" : (clipSeconds == 60 ? "minute" : "\(clipSeconds / 60) minutes")
    }

    // MARK: The library

    func refreshClips() {
        Task.detached {
            let items = ClipLibrary.items()
            await MainActor.run { AppModel.shared.clips = items }
        }
    }

    func open(_ clip: ClipItem) {
        overlay.hide()
        NSWorkspace.shared.open(clip.url)
    }

    func reveal(_ clip: ClipItem) {
        overlay.hide()
        NSWorkspace.shared.activateFileViewerSelecting([clip.url])
    }

    /// Paste into Discord or Messages to send it.
    func copy(_ clip: ClipItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([clip.url as NSURL])
        toast = "Copied. Paste it into Discord or Messages."
    }

    func delete(_ clip: ClipItem) {
        try? FileManager.default.trashItem(at: clip.url, resultingItemURL: nil)
        refreshClips()
    }

    func showClipsFolder() {
        try? FileManager.default.createDirectory(at: ClipLibrary.folder, withIntermediateDirectories: true)
        overlay.hide()
        NSWorkspace.shared.open(ClipLibrary.folder)
    }
}
