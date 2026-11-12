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

    /// How to reach the overlay's Clips tile, for a message over the game.
    private var clipsTileHint: String {
        let number = (OverlayTab.allCases.firstIndex(of: .clips) ?? 1) + 1
        if OverlayHotkey.current == .off { return "Open the overlay from Cellar's menu bar icon, then press \(number)." }
        return "Press \(OverlayHotkey.current.label), then \(number)."
    }

    private func startClips() {
        guard clipRecorder == nil, !clipsStarting else { return }
        clipsStopRequested = false
        // Asking ScreenCaptureKit would pop macOS's question up underneath the overlay.
        guard CGPreflightScreenCaptureAccess() else { return askForScreenRecording() }
        clipsNeedPermission = false
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
                // The game closed while recording was still starting: don't leave it recording nothing.
                if clipsStopRequested {
                    clipsStopRequested = false
                    await recorder.stop()
                    return
                }
                clipRecorder = recorder
                clipsRecording = true
                clipsNeedPermission = false
                watchFrontmostApp()
                overlay.showHUD("Clips on. \(OverlayController.clipHotkeyLabel) saves the last \(clipLengthLabel).", systemImage: "record.circle")
            } catch {
                clipError = error.localizedDescription
                overlay.showHUD("Clips couldn't start. See the Clips tab.", systemImage: "exclamationmark.triangle.fill")
            }
        }
    }

    private func stopClips() {
        guard let recorder = clipRecorder else {
            if clipsStarting { clipsStopRequested = true }
            return
        }
        clipRecorder = nil
        clipsRecording = false
        if let frontmostObserver { NSWorkspace.shared.notificationCenter.removeObserver(frontmostObserver) }
        frontmostObserver = nil
        Task { await recorder.stop() }
    }

    /// macOS draws its question under the overlay, so the overlay has to get out of the way.
    func askForScreenRecording() {
        clipsNeedPermission = true
        overlay.hide()
        // A second ask this launch would wipe a yes that macOS is waiting for a relaunch to apply.
        guard !clipsAskedThisLaunch else { return }
        clipsAskedThisLaunch = true
        Task {
            await resetScreenRecordingEntry()
            CGRequestScreenCaptureAccess()
        }
    }

    /// macOS ties the permission to the app's signature. A yes given to an older signature still shows
    /// as on in System Settings, but doesn't count, and macOS won't ask again while it's there. So this
    /// clears Cellar's own entry first. It touches nothing else.
    private func resetScreenRecordingEntry() async {
        guard let id = ownBundleID else { return }
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", "ScreenCapture", id]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }.value
    }

    /// Runs once for each signature, outside a game, so Clips work by the time a game starts.
    func repairScreenRecordingOnce(gameRunning: Bool) {
        guard !screenRecordingChecked, !gameRunning else { return }
        screenRecordingChecked = true
        let signature = "self-signed-1"
        var state = core.loadState()
        guard autoClips, !CGPreflightScreenCaptureAccess(), state.screenRecordingAskedFor != signature else { return }
        state.screenRecordingAskedFor = signature
        try? core.saveState(state)
        askForScreenRecording()
    }

    func relaunch() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? process.run()
        NSApp.terminate(nil)
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
            let reason = CGPreflightScreenCaptureAccess() ? "Clips are off for this game." : "Clips need permission."
            overlay.showHUD("\(reason) \(clipsTileHint)", systemImage: "record.circle")
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

    /// Called when a game starts. Without permission it only says so: macOS's question shouldn't pop
    /// up over a game that's starting.
    func startClipsForGame() {
        guard autoClips else { return }
        guard CGPreflightScreenCaptureAccess() else {
            clipsNeedPermission = true
            overlay.showHUD("Clips need permission. \(clipsTileHint)", systemImage: "lock.fill")
            return
        }
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
        tell("Copied. Paste it into Discord or Messages.", systemImage: "doc.on.doc")
    }

    /// A short message wherever it'll be seen: the overlay covers the main window's toasts.
    func tell(_ text: String, systemImage: String) {
        if overlay.isVisible {
            overlay.showHUD(text, systemImage: systemImage)
        } else {
            toast = text
        }
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
