import AppKit
import Carbon.HIToolbox
import CellarKit
import SwiftUI

enum OverlayTab: String, CaseIterable, Identifiable {
    case friends = "Friends", clips = "Clips", music = "Music", game = "Game"
    var id: String { rawValue }
}

/// Cellar's in-game overlay: a control strip across the bottom of the screen, above the game, opened with a hotkey. It never
/// touches the game's graphics, so unlike Steam's overlay it can't crash a game.
@MainActor
final class OverlayController {
    static let clipHotkeyLabel = "Option+C"
    private static let overlayKeyID: UInt32 = 1
    private static let clipKeyID: UInt32 = 2

    weak var model: AppModel?
    private var panel: OverlayPanel?
    private var hud: NSPanel?
    private var hudTask: Task<Void, Never>?
    private var previousApp: NSRunningApplication?
    private var overlayKey: EventHotKeyRef?
    private var clipKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var registered: OverlayHotkey?
    private var keyMonitor: Any?
    /// Set while testing the layout with no game running, so it isn't closed straight away.
    private(set) var isDemo = false
    private var spaceObserver: NSObjectProtocol?
    private var shownAt = Date.distantPast

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show(tab: OverlayTab? = nil, demo: Bool = false) {
        guard let model, let screen = NSScreen.main else { return }
        isDemo = demo
        if let tab { model.overlayTab = tab }
        model.overlayClip = nil
        let panel = self.panel ?? makePanel(model)
        self.panel = panel
        // A fresh view each time, so it animates in and nothing's left half-done from last time.
        panel.contentView = OverlayHostingView(rootView: OverlayView().environment(model).preferredColorScheme(.dark))
        previousApp = NSWorkspace.shared.frontmostApplication
        shownAt = Date()
        watchSpaces()
        panel.setFrame(screen.frame, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        // A game holding the mouse lets go of it once it loses focus.
        NSApp.activate()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.16; panel.animator().alphaValue = 1 }
        installKeyMonitor()
        model.refreshClips()
        model.startMusicPolling()
        Task {
            await model.takeSample()
            await model.refreshFriends()
        }
    }

    /// `returnToGame` is false after swiping to another desktop: activating the game would drag you back.
    func hide(returnToGame: Bool = true) {
        guard let panel, panel.isVisible else { return }
        isDemo = false
        removeKeyMonitor()
        model?.stopMusicPolling()
        panel.orderOut(nil)
        if returnToGame { previousApp?.activate() }
        previousApp = nil
    }

    /// Swiping to another desktop closes the overlay, so it never sits on top of that desktop.
    private func watchSpaces() {
        guard spaceObserver == nil else { return }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.spaceChanged() }
        }
    }

    private func spaceChanged() {
        // Opening the overlay can itself report a change, which shouldn't close it straight away.
        guard isVisible, !isDemo, Date().timeIntervalSince(shownAt) > 1 else { return }
        hide(returnToGame: false)
    }

    private func makePanel(_ model: AppModel) -> OverlayPanel {
        let panel = OverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        // Opens on whichever desktop you're on and stays there, so a swipe slides it away with the game.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }

    // MARK: Keys inside the overlay

    /// Esc goes back to the game; 1 to 4 and the arrows change tab, unless something's being typed.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            let characters = event.charactersIgnoringModifiers
            let modified = !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            let handled = MainActor.assumeIsolated { self?.handleKey(code, characters, modified: modified) ?? false }
            return handled ? nil : event
        }
    }

    private func handleKey(_ code: UInt16, _ characters: String?, modified: Bool) -> Bool {
        guard let model, isVisible else { return false }
        let typing = panel?.firstResponder is NSTextView
        if code == UInt16(kVK_Escape) {
            if typing {
                panel?.makeFirstResponder(nil)
            } else if model.overlayClip != nil {
                model.overlayClip = nil
            } else {
                hide()
            }
            return true
        }
        // The clip editor uses the arrows and space for itself.
        guard !typing, !modified, model.overlayClip == nil else { return false }
        let tabs = OverlayTab.allCases
        let current = tabs.firstIndex(of: model.overlayTab) ?? 0
        switch code {
        case UInt16(kVK_LeftArrow):
            model.overlayTab = tabs[max(current - 1, 0)]
            return true
        case UInt16(kVK_RightArrow):
            model.overlayTab = tabs[min(current + 1, tabs.count - 1)]
            return true
        default:
            guard let number = characters.flatMap({ Int($0) }), (1...tabs.count).contains(number) else { return false }
            model.overlayTab = tabs[number - 1]
            return true
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: Small notices over the game

    /// A notice that never takes focus from the game, for saving clips and the like.
    func showHUD(_ text: String, systemImage: String) {
        guard let screen = NSScreen.main else { return }
        let hud = self.hud ?? makeHUD()
        self.hud = hud
        let view = NSHostingView(rootView: OverlayHUD(text: text, systemImage: systemImage).preferredColorScheme(.dark))
        hud.contentView = view
        let size = view.fittingSize
        hud.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height - 44,
                            width: size.width, height: size.height), display: true)
        hud.alphaValue = 0
        hud.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; hud.animator().alphaValue = 1 }
        hudTask?.cancel()
        hudTask = Task { [weak hud] in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled, let hud else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; hud.animator().alphaValue = 0 }, completionHandler: { [weak hud] in
                MainActor.assumeIsolated { hud?.orderOut(nil) }
            })
        }
    }

    private func makeHUD() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        return panel
    }

    // MARK: Hotkeys

    /// The hotkey exists only while a game runs, so Shift+Tab works normally the rest of the time.
    func setHotkeyActive(_ active: Bool) {
        let choice = OverlayHotkey.current
        if !active || choice == .off {
            if let overlayKey { UnregisterEventHotKey(overlayKey) }
            overlayKey = nil
            registered = nil
            return
        }
        guard registered != choice else { return }
        if let overlayKey { UnregisterEventHotKey(overlayKey) }
        overlayKey = nil
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x43454C52), id: Self.overlayKeyID)   // 'CELR'
        if RegisterEventHotKey(UInt32(kVK_Tab), choice.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr {
            overlayKey = ref
            registered = choice
        }
    }

    /// Option+C saves a clip. It's there through the whole game, so it can say why if it can't.
    func setClipHotkeyActive(_ active: Bool) {
        guard active != (clipKey != nil) else { return }
        if let clipKey { UnregisterEventHotKey(clipKey) }
        clipKey = nil
        guard active else { return }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x43454C52), id: Self.clipKeyID)
        if RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &ref) == noErr {
            clipKey = ref
        }
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let keyID = pressed.id
            let controller = Unmanaged<OverlayController>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if keyID == OverlayController.clipKeyID {
                        controller.model?.saveClip()
                    } else {
                        controller.toggle()
                    }
                }
            }
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

/// Lets the first click on a button or slider count. Otherwise it can be used up on the panel taking focus.
private final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct OverlayHUD: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage).foregroundStyle(Theme.wine)
            Text(text).font(.cCallout.weight(.semibold))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Capsule().fill(.black.opacity(0.78)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
        .foregroundStyle(.white)
        .padding(4)
        .fixedSize()
    }
}

// MARK: The strip

/// The game stays in view up top. Everything else sits along the bottom: what you're playing, four
/// tiles, and the selected tile's panel, after a console's control centre.
struct OverlayView: View {
    @Environment(AppModel.self) private var model
    @State private var appeared = false

    var body: some View {
        GeometryReader { geometry in
            let height = panelHeight(in: geometry.size.height)
            ZStack(alignment: .bottom) {
                // Darkest just behind the strip, so as much of the game as possible stays clear.
                LinearGradient(stops: [.init(color: .black.opacity(0.08), location: 0),
                                       .init(color: .black.opacity(0.3), location: dimStart(height, of: geometry.size.height)),
                                       .init(color: .black.opacity(0.9), location: min(dimStart(height, of: geometry.size.height) + 0.2, 1))],
                               startPoint: .top, endPoint: .bottom)
                VStack(spacing: 12) {
                    // Clicking the visible part of the game goes back to it.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { model.overlay.hide() }
                    OverlayHeader()
                    OverlayTiles()
                    panel
                        .frame(height: height)
                        .padding(16)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(red: 0.07, green: 0.065, blue: 0.09).opacity(0.97)))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
                    OverlayHints()
                }
                .frame(maxWidth: 1240)
                .padding(.horizontal, 40)
                .padding(.bottom, 20)
                .offset(y: appeared ? 0 : 28)
                .opacity(appeared ? 1 : 0)
            }
            .animation(.smooth(duration: 0.22), value: model.overlayTab)
            .animation(.smooth(duration: 0.22), value: model.overlayClip == nil)
        }
        .tint(.white)
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            if let toast = model.toast {
                Toast(text: toast) { model.toast = nil }.padding(.top, 26)
            }
        }
        .onAppear { withAnimation(.smooth(duration: 0.24)) { appeared = true } }
    }

    /// Each tile only takes the room it needs, so short ones leave more of the game showing.
    private func panelHeight(in available: CGFloat) -> CGFloat {
        let wanted: CGFloat = switch model.overlayTab {
        case .friends: 270
        case .music: 290
        case .clips: model.overlayClip == nil ? 400 : 470
        case .game: 470
        }
        return min(wanted, available * 0.56)
    }

    private func dimStart(_ panel: CGFloat, of total: CGFloat) -> CGFloat {
        max(0.1, 1 - (panel + 250) / max(total, 1))
    }

    private var panel: some View {
        Group {
            switch model.overlayTab {
            case .friends: OverlayFriendsTab()
            case .clips: OverlayClipsTab()
            case .music: OverlayMusicTab()
            case .game: OverlayGameTab()
            }
        }
        .id(model.overlayTab)
        .transition(.opacity)
        .animation(.smooth(duration: 0.18), value: model.overlayTab)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct OverlayHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(model.runningGame?.name ?? "Cellar")
                .font(.cellar(24, .heavy))
                .lineLimit(1)
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text(subtitle).font(.cCallout).foregroundStyle(.white.opacity(0.82)).lineLimit(1)
            }
            Spacer(minLength: 16)
            OverlayChips()
            Button("Resume") { model.overlay.hide() }
                .buttonStyle(PillButtonStyle())
                .help("Back to the game (\(OverlayHotkey.current.label))")
        }
    }

    private var subtitle: String {
        guard let game = model.runningGame, let start = model.sessionStarts[game.id] else { return "" }
        return AppModel.playTime(Date().timeIntervalSince(start)) + " this session"
    }
}

/// Connection, battery, heat and the time, since a full-screen game hides the menu bar.
struct OverlayChips: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            let status = model.steamStatus
            chip {
                Circle().fill(status.color).frame(width: 7, height: 7)
                Text(status.title)
            }
            if let sample = model.stats.last {
                if let battery = sample.battery {
                    chip {
                        Image(systemName: sample.charging ? "battery.100.bolt" : "battery.75")
                        Text("\(Int((battery * 100).rounded()))%")
                    }
                }
                if sample.thermal > .normal {
                    chip {
                        Image(systemName: "thermometer.medium").foregroundStyle(sample.thermal >= .hot ? Color.red : Color.orange)
                        Text(sample.thermal.title)
                    }
                }
            }
            if model.clipsRecording {
                chip {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text("Clips on")
                }
            }
            TimelineView(.periodic(from: .now, by: 20)) { context in
                chip { Text(context.date.formatted(date: .omitted, time: .shortened)) }
            }
        }
    }

    private func chip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 5) { content() }
            .font(.cellar(12, .semibold))
            .monospacedDigit()
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(.white.opacity(0.09)))
    }
}

/// The four big tiles. Each says something useful without being opened.
struct OverlayTiles: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            ForEach(OverlayTab.allCases) { tab in
                let selected = model.overlayTab == tab
                Button { model.overlayTab = tab } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(tab.rawValue).font(.cellar(15, .bold))
                        Text(summary(tab)).font(.cCaption).lineLimit(1).opacity(0.84)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .frame(height: 68)
                    .foregroundStyle(selected ? .black : .white)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(selected ? Color.white : Color(red: 0.07, green: 0.065, blue: 0.09).opacity(0.92)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected ? .clear : Theme.line))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func summary(_ tab: OverlayTab) -> String {
        switch tab {
        case .friends:
            if model.steamOffline { return "Steam is offline" }
            let count = model.friendsInGame.count + model.friendsOnline.count
            return count == 0 ? "Nobody online" : "\(count) online"
        case .clips:
            return model.clipsRecording ? "Recording" : "Off"
        case .music:
            return model.spotify.name ?? "Spotify"
        case .game:
            return "Heat: \(model.stats.last?.thermal.title ?? "Normal")"
        }
    }
}

struct OverlayHints: View {
    var body: some View {
        HStack(spacing: 18) {
            hint("esc", "Back to game")
            hint("1–4", "Switch tile")
            hint(OverlayController.clipHotkeyLabel, "Save a clip")
            Spacer()
        }
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.cellar(10, .bold))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.12)))
            Text(text).font(.cCaption)
        }
        .foregroundStyle(.white.opacity(0.55))
    }
}

/// The surface every panel in the overlay sits on.
struct OverlayCard<Content: View>: View {
    var title: String?
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title.uppercased())
                    .font(.cCaption.weight(.bold)).tracking(1.1)
                    .foregroundStyle(.white.opacity(0.55))
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.1)))
    }
}

/// A line of history, drawn small enough to sit inside a tile.
struct Sparkline: View {
    let values: [Double]
    var maximum: Double = 1
    var color: Color = .white

    var body: some View {
        GeometryReader { geometry in
            let points = values.suffix(60)
            let count = max(points.count - 1, 1)
            let height = geometry.size.height
            let step = geometry.size.width / CGFloat(count)
            let ceiling = max(maximum, 0.0001)
            let locations = points.enumerated().map { index, value in
                CGPoint(x: CGFloat(index) * step, y: height - CGFloat(min(value / ceiling, 1)) * height)
            }
            if locations.count > 1 {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height))
                    locations.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: locations.last?.x ?? 0, y: height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [color.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                Path { path in
                    path.move(to: locations[0])
                    locations.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
