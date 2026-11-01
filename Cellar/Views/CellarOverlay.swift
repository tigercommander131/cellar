import AppKit
import Carbon.HIToolbox
import CellarKit
import SwiftUI

enum OverlayTab: String, CaseIterable, Identifiable {
    case home = "Home", friends = "Friends", clips = "Clips", performance = "Performance", game = "Game"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .friends: "person.2.fill"
        case .clips: "play.rectangle.on.rectangle.fill"
        case .performance: "gauge.with.dots.needle.67percent"
        case .game: "note.text"
        }
    }
}

/// Cellar's in-game overlay: a native full-screen layer above the game, opened with a hotkey. It never
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

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show(tab: OverlayTab? = nil, demo: Bool = false) {
        guard let model, let screen = NSScreen.main else { return }
        isDemo = demo
        if let tab { model.overlayTab = tab }
        let panel = self.panel ?? makePanel(model)
        self.panel = panel
        previousApp = NSWorkspace.shared.frontmostApplication
        panel.setFrame(screen.frame, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        // A game holding the mouse lets go of it once it loses focus.
        NSApp.activate()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.16; panel.animator().alphaValue = 1 }
        installKeyMonitor()
        model.refreshClips()
        Task {
            await model.takeSample()
            await model.refreshFriends()
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        isDemo = false
        removeKeyMonitor()
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

    // MARK: Keys inside the overlay

    /// Esc goes back to the game; 1 to 5 and the arrows change tab, unless something's being typed.
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
            } else {
                hide()
            }
            return true
        }
        guard !typing, !modified else { return false }
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

    /// Option+C saves a clip, only while Clips are recording.
    func setClipHotkeyActive(_ active: Bool) {
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

struct OverlayHUD: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage).foregroundStyle(Color.accentColor)
            Text(text).font(.callout.weight(.semibold))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Capsule().fill(.black.opacity(0.78)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
        .foregroundStyle(.white)
        .padding(4)
        .fixedSize()
    }
}

// MARK: The layer

/// Everything over a dimmed, blurred game: who and what's going on along the top, then one of five tabs.
struct OverlayView: View {
    @Environment(AppModel.self) private var model
    @State private var appeared = false

    var body: some View {
        @Bindable var model = model
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color.black.opacity(0.42)
            RadialGradient(colors: [Color(red: 0.45, green: 0.06, blue: 0.14).opacity(0.55), .clear],
                           center: .topLeading, startRadius: 40, endRadius: 900)
            VStack(spacing: 0) {
                OverlayTopBar()
                OverlayTabBar()
                    .padding(.top, 22)
                Group {
                    switch model.overlayTab {
                    case .home: OverlayHomeTab()
                    case .friends: OverlayFriendsTab()
                    case .clips: OverlayClipsTab()
                    case .performance: OverlayPerformanceTab()
                    case .game: OverlayGameTab()
                    }
                }
                .id(model.overlayTab)
                .transition(.opacity.combined(with: .offset(y: 8)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 20)
                OverlayHints()
                    .padding(.top, 12)
            }
            .frame(maxWidth: 1400)
            .padding(.horizontal, 44)
            .padding(.vertical, 34)
            .scaleEffect(appeared ? 1 : 0.985)
            .opacity(appeared ? 1 : 0)
        }
        .ignoresSafeArea()
        .animation(.smooth(duration: 0.22), value: model.overlayTab)
        .overlay(alignment: .top) {
            if let toast = model.toast {
                Toast(text: toast) { model.toast = nil }.padding(.top, 26)
            }
        }
        .onAppear { withAnimation(.smooth(duration: 0.28)) { appeared = true } }
    }
}

struct OverlayTopBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ArtworkImage(url: model.runningGame?.artwork?.capsule, fallbackTitle: "")
                .frame(width: 48, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.14)))
            VStack(alignment: .leading, spacing: 4) {
                Text(model.runningGame?.name ?? "Cellar")
                    .font(.system(size: 28, weight: .heavy))
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(subtitle).font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer(minLength: 20)
            OverlayChips()
            Button { model.overlay.hide() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text("Resume")
                }
            }
            .buttonStyle(PillButtonStyle())
            .help("Back to the game (\(OverlayHotkey.current.label))")
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let game = model.runningGame {
            if let start = model.sessionStarts[game.id] {
                parts.append("Playing for \(AppModel.playTime(Date().timeIntervalSince(start)))")
            }
            parts.append(game.profile.backend.shortName)
            if let preset = game.profile.preset { parts.append(preset.title) }
        }
        return parts.joined(separator: "  ·  ")
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
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(.white.opacity(0.09)))
    }
}

struct OverlayTabBar: View {
    @Environment(AppModel.self) private var model
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 4) {
            ForEach(OverlayTab.allCases) { tab in
                Button { model.overlayTab = tab } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tab.icon).font(.system(size: 12, weight: .semibold))
                        Text(tab.rawValue).font(.system(size: 14, weight: .semibold))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .foregroundStyle(model.overlayTab == tab ? .white : .white.opacity(0.62))
                    .background {
                        if model.overlayTab == tab {
                            Capsule().fill(Color.accentColor).matchedGeometryEffect(id: "tab", in: pill)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

struct OverlayHints: View {
    var body: some View {
        HStack(spacing: 18) {
            hint("esc", "Back to game")
            hint("1–5", "Switch tab")
            hint(OverlayController.clipHotkeyLabel, "Save clip, while Clips are on")
            Spacer()
        }
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.12)))
            Text(text).font(.caption)
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
                    .font(.caption.weight(.bold)).tracking(1.1)
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
    var color: Color = .accentColor

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
