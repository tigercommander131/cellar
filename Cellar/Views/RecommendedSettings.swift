import AppKit
import CellarKit
import SwiftUI

/// What to set in a game for this Mac: rows with the value on the right, after Higgsfield's settings
/// panel, tagged "Recommended" like Klaviyo's options on Mobbin.
struct RecommendedSettingsView: View {
    @Environment(AppModel.self) private var model
    let game: Game
    /// Off where the preset choices are already on the same screen.
    var showsPreset = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let advice = model.settingsAdvice[game.id] {
                header(advice)
                if let note = advice.note {
                    Text(note).font(.cCallout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 0) {
                    ForEach(Array(advice.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().opacity(0.4) }
                        AdviceRow(row: row)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.05)))
                if showsPreset { presetRow(advice) }
                footer(advice)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Working out settings for this Mac…").font(.cCallout).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: game.id) { await model.loadAdvice(for: game) }
    }

    private func header(_ advice: SettingsAdvice) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recommended for this Mac").font(.cHeadline).fixedSize(horizontal: false, vertical: true)
                if let specs = model.macSpecs {
                    Text(specs.summary).font(.cCaption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(advice.target).font(.cCallout.weight(.bold)).monospacedDigit()
                Text("Rough aim").font(.cCaption2).foregroundStyle(.secondary)
            }
        }
    }

    private func presetRow(_ advice: SettingsAdvice) -> some View {
        let current = model.core.profiles.profile(for: game.id).preset ?? .quality
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Cellar preset: \(advice.preset.title)").font(.cCallout.weight(.semibold))
                Text(game.profile.backend.supportsFrameCap ? "Includes a frame limit." : "\(game.profile.backend.shortName) can't limit frames from Cellar, so set the limit in the game.")
                    .font(.cCaption).foregroundStyle(.secondary)
            }
            Spacer()
            if current == advice.preset {
                Label("In use", systemImage: "checkmark").font(.cCaption.weight(.semibold)).foregroundStyle(.green)
            } else {
                Button("Use It") { model.usePreset(advice.preset, for: game) }
                    .buttonStyle(GlassButtonStyle())
            }
        }
    }

    @ViewBuilder private func footer(_ advice: SettingsAdvice) -> some View {
        switch advice.source {
        case .curated:
            Text("Change these in the game's own menu. They're starting points based on its options, not measured on your Mac.")
                .font(.cCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .wiki(let page):
            HStack(spacing: 4) {
                Text("General advice, not researched for this game. Options from").font(.cCaption).foregroundStyle(.secondary)
                Button("PCGamingWiki") {
                    if let url = URL(string: "https://www.pcgamingwiki.com/wiki/\(page)") { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.link)
                .font(.cCaption)
            }
        case .general:
            Text("General advice, not researched for this game, and its menus may use other names.")
                .font(.cCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AdviceRow: View {
    let row: SettingsAdvice.Row

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.cCallout.weight(.semibold))
                Text(row.why).font(.cCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(row.value)
                .font(.cCallout.weight(.semibold))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(.white.opacity(0.14)))
                .fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}
