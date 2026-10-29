import CellarKit
import SwiftUI

/// First run: a checklist on the left that ticks off as setup runs, art on the right.
struct SetupView: View {
    @Environment(AppModel.self) private var model

    private struct Item: Identifiable {
        let step: CellarCore.SetupStep
        let title: String
        var id: String { step.rawValue }
    }

    private let items = [
        Item(step: .checks, title: "Checking your Mac"),
        Item(step: .engine, title: "Downloading the Wine engine"),
        Item(step: .graphics, title: "Adding D3DMetal, DXMT and game fixes"),
        Item(step: .bottle, title: "Creating the Windows environment"),
        Item(step: .steam, title: "Installing Steam"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                AppMark(size: 56)
                    .padding(.bottom, 22)
                Text(model.phase == .settingUp ? "Setting things up…" : "Welcome to Cellar")
                    .font(.system(size: 30, weight: .bold))
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)

                if model.phase == .settingUp || model.setupError != nil {
                    ProgressView(value: overallProgress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                        .padding(.top, 26)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(items) { item in
                            ChecklistRow(title: item.title, state: state(of: item.step), detail: detail(for: item.step))
                        }
                    }
                    .padding(.top, 20)
                } else {
                    hostSummary.padding(.top, 26)
                }

                if let error = model.setupError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                        .padding(.top, 18)
                        .textSelection(.enabled)
                }

                HStack(spacing: 12) {
                    if model.phase == .needsSetup || model.setupError != nil {
                        Button(model.setupError == nil ? "Set Up" : "Try Again") { model.runSetup() }
                            .buttonStyle(PillButtonStyle())
                            .disabled(!model.host.problems.filter { !$0.contains("Rosetta") }.isEmpty)
                            .keyboardShortcut(.defaultAction)
                    }
                    if model.setupError != nil {
                        Button("Show Logs") { model.openLogs() }
                            .buttonStyle(.link)
                    }
                }
                .padding(.top, 28)
                Spacer()
                Text("D3DMetal is Apple software, downloaded from Gcenx's Game Porting Toolkit build under Apple's license. Cellar isn't affiliated with CodeWeavers, Valve or Apple.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: 440, alignment: .leading)
            .padding(.horizontal, 56)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            SetupArt()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var subtitle: String {
        if model.phase == .settingUp { return model.setupMessage.isEmpty ? "This takes a few minutes the first time." : model.setupMessage }
        return "Play your Windows Steam games on this Mac. Setup downloads about 1.5 GB and installs Steam."
    }

    private var hostSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            let host = model.host
            ChecklistRow(title: "Apple silicon, macOS \(host.macOSVersion.majorVersion)", state: host.isAppleSilicon && host.macOSVersion.majorVersion >= 26 ? .done : .failed)
            ChecklistRow(title: host.rosettaInstalled ? "Rosetta 2 installed" : "Rosetta 2 will be installed", state: host.rosettaInstalled ? .done : .pending)
            ChecklistRow(title: "\(host.availableDiskBytes / 1_000_000_000) GB free", state: host.hasRoomForSetup ? .done : .failed)
            ChecklistRow(title: "\(host.memoryGB) GB memory" + (host.prefersLowMemoryMode ? " · low-memory mode on" : ""), state: .done)
        }
    }

    private var currentIndex: Int {
        guard let step = model.setupStep else { return 0 }
        return items.firstIndex { $0.step == step } ?? items.count
    }

    private var overallProgress: Double {
        let base = Double(min(currentIndex, items.count)) / Double(items.count)
        let within = (model.setupProgress ?? 0) / Double(items.count)
        return min(1, base + within)
    }

    private func state(of step: CellarCore.SetupStep) -> ChecklistRow.State {
        guard let index = items.firstIndex(where: { $0.step == step }) else { return .pending }
        if index < currentIndex { return .done }
        if index == currentIndex { return model.setupError == nil ? .active : .failed }
        return .pending
    }

    private func detail(for step: CellarCore.SetupStep) -> String? {
        guard state(of: step) == .active, let p = model.setupProgress else { return nil }
        return "\(Int(p * 100))%"
    }
}

struct ChecklistRow: View {
    enum State { case pending, active, done, failed }
    let title: String
    let state: State
    var detail: String?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                switch state {
                case .pending: Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
                case .active: ProgressView().controlSize(.small)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
                }
            }
            .frame(width: 18)
            Text(title)
                .foregroundStyle(state == .pending ? .secondary : .primary)
                .fontWeight(state == .active ? .semibold : .regular)
            if let detail {
                Text(detail).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .font(.body)
    }
}

/// The right half of the setup screen: a slow-moving wine-and-amber gradient.
struct SetupArt: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let t = Float(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 60))
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.5 + 0.12 * sin(t / 5), 0.5 + 0.1 * cos(t / 7)], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ],
                colors: [
                    Color(red: 0.16, green: 0.03, blue: 0.07), Color(red: 0.45, green: 0.07, blue: 0.16), Color(red: 0.20, green: 0.04, blue: 0.10),
                    Color(red: 0.55, green: 0.12, blue: 0.20), Color(red: 0.90, green: 0.45, blue: 0.25), Color(red: 0.35, green: 0.06, blue: 0.14),
                    Color(red: 0.10, green: 0.02, blue: 0.05), Color(red: 0.30, green: 0.05, blue: 0.12), Color(red: 0.08, green: 0.02, blue: 0.04),
                ]
            )
        }
        .overlay {
            Image(systemName: "wineglass.fill")
                .font(.system(size: 160, weight: .light))
                .foregroundStyle(.white.opacity(0.12))
                .blendMode(.plusLighter)
        }
        .ignoresSafeArea()
    }
}
