import CellarKit
import Sparkle
import SwiftUI

@main
struct CellarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared
    private let updaterDelegate: UpdaterDelegate
    private let updater: SPUStandardUpdaterController

    init() {
        let delegate = UpdaterDelegate()
        updaterDelegate = delegate
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
        updater = controller
        AppModel.shared.checkForUpdates = { controller.checkForUpdates(nil) }
        // Steam artwork is loaded with AsyncImage; give it a real disk cache.
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 300 << 20)
    }

    var body: some Scene {
        Window("Cellar", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(.dark)
                .task { model.start() }
                .onOpenURL { model.handle($0) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 760)
        .handlesExternalEvents(matching: ["*"])
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates(nil) }
            }
            CommandMenu("Games") {
                Button("Open Steam") { model.openSteam() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.phase != .ready)
                Button("Show Overlay") { model.overlay.toggle() }
                    .disabled(model.runningGame == nil)
                Button("Save Clip") { model.saveClip() }
                    .disabled(!model.clipsRecording)
                Button("Force Quit All Games") { model.stopAll() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Divider()
                Button("Show Logs") { model.openLogs() }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(.dark)
        }

        MenuBarExtra(isInserted: Binding(get: { model.menuBarIcon }, set: { model.setMenuBarIcon($0) })) {
            MenuBarPanel()
                .environment(model)
        } label: {
            Image(systemName: "wineglass.fill")
                .accessibilityLabel("Cellar")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Beta versions sit in the same update feed, tagged, and only reach people who switched them on.
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        CellarCore().loadState().betaUpdates == true ? ["beta"] : []
    }
}

/// Cellar keeps running with its window closed, so the overlay still works during a game.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .loading:
                ProgressView().controlSize(.large)
            case .needsSetup, .settingUp:
                SetupView()
            case .ready:
                MainView()
            }
        }
        .alert("You're on battery", isPresented: Binding(get: { model.batteryPromptGame != nil }, set: { if !$0 { model.batteryPromptGame = nil } })) {
            Button("Use Battery Preset") { model.answerBatteryPrompt(usePreset: true) }
            Button("Keep My Settings") { model.answerBatteryPrompt(usePreset: false) }
            Button("Don't Ask Again") { model.answerBatteryPrompt(usePreset: false, dontAskAgain: true) }
        } message: {
            Text("The Battery preset limits \(model.batteryPromptGame?.name ?? "this game") to 30 fps for this session, which saves a lot of power.")
        }
        .alert("\(model.blockedPromptGame?.name ?? "This game") may not run", isPresented: Binding(get: { model.blockedPromptGame != nil }, set: { if !$0 { model.blockedPromptGame = nil } })) {
            Button("Play Anyway") {
                if let game = model.blockedPromptGame { model.play(game, knowingItsBlocked: true) }
                model.blockedPromptGame = nil
            }
            Button("Cancel", role: .cancel) { model.blockedPromptGame = nil }
        } message: {
            Text(model.blockedPromptGame.flatMap { model.verdicts[$0.id]?.reasons.first?.text } ?? "Its anti-cheat doesn't work under Wine.")
        }
        .alert("\(model.selfFixPrompt?.game.name ?? "This game") closed right after starting", isPresented: Binding(get: { model.selfFixPrompt != nil }, set: { if !$0, model.selfFixPrompt != nil { model.answerSelfFixPrompt(tryIt: false) } })) {
            Button("Try \(model.selfFixPrompt?.next.shortName ?? "Another Option")") { model.answerSelfFixPrompt(tryIt: true) }
            Button("I Closed It", role: .cancel) { model.answerSelfFixPrompt(tryIt: false) }
        } message: {
            Text("If it crashed, a different graphics option may fix it.")
        }
        .alert("Cellar", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.checkForPackUpdates()
        }
    }
}
