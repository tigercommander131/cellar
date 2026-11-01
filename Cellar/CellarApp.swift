import CellarKit
import Sparkle
import SwiftUI

@main
struct CellarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    init() {
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
