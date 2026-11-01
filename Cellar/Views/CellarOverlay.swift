import AppKit
import Carbon.HIToolbox
import CellarKit
import SwiftUI

/// Cellar's in-game overlay: a native panel above the game, opened with a hotkey. It never touches
/// the game's graphics, so unlike Steam's overlay it can't crash a game.
@MainActor
final class OverlayController {
    weak var model: AppModel?
    private var panel: OverlayPanel?
    private var previousApp: NSRunningApplication?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        guard let model, let screen = NSScreen.main else { return }
        let panel = self.panel ?? makePanel(model)
        self.panel = panel
        previousApp = NSWorkspace.shared.frontmostApplication
        panel.setFrame(screen.frame, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        // A game holding the mouse lets go of it once it loses focus.
        NSApp.activate()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        Task { await model.refreshFriends() }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        previousApp?.activate()
        previousApp = nil
    }

    private func makePanel(_ model: AppModel) -> OverlayPanel {
        let panel = OverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: OverlayView().environment(model).preferredColorScheme(.dark))
        return panel
    }

    // MARK: Hotkey

    /// The hotkey exists only while a game runs, so Shift+Tab works normally the rest of the time.
    func setHotkeyActive(_ active: Bool) {
        let choice = OverlayHotkey.current
        if !active || choice == .off {
            if let hotKey { UnregisterEventHotKey(hotKey) }
            hotKey = nil
            registered = nil
            return
        }
        guard registered != choice else { return }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x43454C52), id: 1)   // 'CELR'
        if RegisterEventHotKey(UInt32(kVK_Tab), choice.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr {
            hotKey = ref
            registered = choice
        }
    }

    private var registered: OverlayHotkey?

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let controller = Unmanaged<OverlayController>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { controller.toggle() } }
            return noErr
        }, 1, &spec, me, &handler)
    }
}

enum OverlayHotkey: String, CaseIterable, Identifiable {
    case shiftTab, optionTab, off
    var id: String { rawValue }

    static var current: OverlayHotkey {
        UserDefaults.standard.string(forKey: "overlayHotkey").flatMap(OverlayHotkey.init) ?? .shiftTab
    }

    var label: String {
        switch self {
        case .shiftTab: "Shift+Tab"
        case .optionTab: "Option+Tab"
        case .off: "Off"
        }
    }

    var carbonModifiers: UInt32 {
        switch self {
        case .shiftTab: UInt32(shiftKey)
        case .optionTab: UInt32(optionKey)
        case .off: 0
        }
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Dimmed game on the left, a friends panel on the right (status rows with actions, after Discord).
struct OverlayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture { model.overlay.hide() }
            panel
                .frame(width: 400)
                .background(.ultraThickMaterial)
                .environment(\.colorScheme, .dark)
        }
        .onExitCommand { model.overlay.hide() }
        .overlay(alignment: .top) {
            if let toast = model.toast {
                Toast(text: toast) { model.toast = nil }.padding(.top, 40)
            }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !model.friendsLoaded {
                        HStack { ProgressView().controlSize(.small); Text("Checking who's on…").foregroundStyle(.secondary) }
                    }
                    section("Playing now", model.friendsInGame)
                    section("Online", model.friendsOnline)
                    if model.friendsLoaded, model.friendsInGame.isEmpty, model.friendsOnline.isEmpty {
                        Text("None of your friends are online.").foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            Divider().opacity(0.4)
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ArtworkImage(url: model.runningGame?.artwork?.capsule, fallbackTitle: "")
                .frame(width: 44, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.runningGame?.name ?? "Cellar").font(.headline).lineLimit(2)
                Text(lobbyStatus).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.overlay.hide() } label: { Image(systemName: "xmark") }
                .buttonStyle(GlassButtonStyle())
                .help("Back to game (\(OverlayHotkey.current.label))")
                .accessibilityLabel("Back to game")
        }
        .padding(20)
    }

    private var lobbyStatus: String {
        if model.ownLobby != nil || model.ownConnect != nil { return "Friends can join you" }
        if model.ownApp != nil { return "Host a lobby in the game to invite friends" }
        return "\(OverlayHotkey.current.label) to go back"
    }

    @ViewBuilder private func section(_ title: String, _ friends: [SteamFriend]) -> some View {
        if !friends.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(title.uppercased())  \(friends.count)")
                    .font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.secondary)
                ForEach(friends) { OverlayFriendRow(friend: $0) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { model.openSteam() } label: { Label("Steam", systemImage: "storefront") }
                .buttonStyle(GlassButtonStyle())
            Spacer()
            Button(role: .destructive) { model.overlay.hide(); model.stopAll() } label: { Label("Force Quit", systemImage: "stop.fill") }
                .buttonStyle(GlassButtonStyle())
        }
        .padding(16)
    }
}

struct OverlayFriendRow: View {
    @Environment(AppModel.self) private var model
    let friend: SteamFriend

    var body: some View {
        HStack(spacing: 10) {
            Avatar(friend: friend, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(friend.name).font(.callout.weight(.semibold)).lineLimit(1)
                Text(friend.state == .inGame ? (friend.game ?? "In a game") : (friend.state == .away ? "Away" : "Online"))
                    .font(.caption)
                    .foregroundStyle(friend.state == .inGame ? .green : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if friend.joinLink != nil, friend.appID != model.ownApp || model.ownLobby == nil {
                Button("Join") { model.join(friend) }
                    .buttonStyle(PillButtonStyle())
            }
            if model.ownApp != nil {
                if model.invitedFriends.contains(friend.id) {
                    Image(systemName: "checkmark").foregroundStyle(.green).help("Invited")
                } else {
                    Button("Invite") { model.invite(friend) }
                        .buttonStyle(GlassButtonStyle())
                }
            }
            Button { model.chat(with: friend) } label: { Image(systemName: "bubble.left.fill") }
                .buttonStyle(GlassButtonStyle())
                .help("Chat in Steam")
                .accessibilityLabel("Chat with \(friend.name) in Steam")
        }
    }
}
