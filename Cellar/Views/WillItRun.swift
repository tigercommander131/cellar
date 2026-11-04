import CellarKit
import SwiftUI

extension CompatibilityVerdict {
    var color: Color {
        switch self {
        case .runsWell: .green
        case .shouldRun: Color(red: 0.35, green: 0.78, blue: 0.82)
        case .mayStruggle: .orange
        case .blocked: .red
        case .unknown: .gray
        }
    }

    var icon: String {
        switch self {
        case .runsWell: "checkmark.seal.fill"
        case .shouldRun: "hand.thumbsup.fill"
        case .mayStruggle: "exclamationmark.triangle.fill"
        case .blocked: "nosign"
        case .unknown: "questionmark.circle.fill"
        }
    }
}

extension CompatibilityReason.Kind {
    var icon: String {
        switch self {
        case .good: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .bad: "nosign"
        }
    }

    var color: Color {
        switch self {
        case .good: .green
        case .info: .secondary
        case .warning: .orange
        case .bad: .red
        }
    }
}

/// A pill naming the verdict.
struct VerdictPill: View {
    let verdict: CompatibilityVerdict

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: verdict.icon)
            Text(verdict.title)
        }
        .font(.cellar(11, .bold))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(.black.opacity(0.55)))
        .overlay(Capsule().strokeBorder(verdict.color.opacity(0.7)))
        .foregroundStyle(verdict.color)
    }
}

/// Just the icon, for the small covers on the shelf.
struct VerdictDot: View {
    let verdict: CompatibilityVerdict

    var body: some View {
        Image(systemName: verdict.icon)
            .font(.cellar(11, .bold))
            .foregroundStyle(verdict.color)
            .frame(width: 22, height: 22)
            .background(Circle().fill(.black.opacity(0.65)))
            .help(verdict.title)
            .accessibilityLabel(verdict.title)
    }
}

/// A verdict pill that explains itself when clicked.
struct VerdictButton: View {
    let game: Game
    let assessment: CompatibilityAssessment
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { VerdictPill(verdict: assessment.verdict) }
            .buttonStyle(.plain)
            .help("Why Cellar says this")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VerdictDetails(gameID: game.id, assessment: assessment)
                    .padding(16)
                    .frame(width: 340)
                    .preferredColorScheme(.dark)
            }
    }
}

struct VerdictReasons: View {
    let reasons: [CompatibilityReason]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(reasons) { reason in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: reason.kind.icon).foregroundStyle(reason.kind.color).frame(width: 16)
                    Text(reason.text).fixedSize(horizontal: false, vertical: true)
                }
                .font(.cCallout)
            }
        }
    }
}

/// The verdict, why, and the player's own say on it.
struct VerdictDetails: View {
    @Environment(AppModel.self) private var model
    let gameID: String
    let assessment: CompatibilityAssessment
    var showsReport = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Will it run?").font(.cHeadline)
                Spacer()
                VerdictPill(verdict: assessment.verdict)
            }
            if assessment.reasons.isEmpty {
                Text("Cellar has nothing to go on yet. Try it and say how it went.").font(.cCallout).foregroundStyle(.secondary)
            } else {
                VerdictReasons(reasons: assessment.reasons)
            }
            if showsReport { WorksButtons(gameID: gameID) }
        }
    }
}

/// "Works" or "Doesn't work" on this Mac. Clicking the current answer takes it back.
struct WorksButtons: View {
    @Environment(AppModel.self) private var model
    let gameID: String

    var body: some View {
        let current = model.report(for: gameID)
        HStack(spacing: 8) {
            Text("On this Mac:").font(.cCaption).foregroundStyle(.secondary)
            answer("It works", "hand.thumbsup.fill", true, current, .green)
            answer("It doesn't", "hand.thumbsdown.fill", false, current, .orange)
        }
    }

    private func answer(_ title: String, _ icon: String, _ value: Bool, _ current: Bool?, _ tint: Color) -> some View {
        Button { model.report(current == value ? nil : value, for: gameID) } label: {
            Label(title, systemImage: icon)
                .font(.cCaption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(current == value ? tint.opacity(0.3) : .white.opacity(0.08)))
                .overlay(Capsule().strokeBorder(current == value ? tint : .white.opacity(0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Library's search: any game on Steam, whether or not it's installed, and what Cellar thinks of it.
struct WillItRunSearch: View {
    @Environment(AppModel.self) private var model
    @State private var term = ""
    @State private var results: [CompatibilityService.StoreMatch] = []
    @State private var searching = false
    @State private var searchedFor = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Will it run? Search any game on Steam", text: $term)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await search() } }
                if searching {
                    ProgressView().controlSize(.small)
                } else if !term.isEmpty {
                    Button { clear() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.1)))

            if !results.isEmpty {
                VStack(spacing: 8) {
                    ForEach(results) { WillItRunRow(match: $0) }
                }
            } else if !searching, !searchedFor.isEmpty, searchedFor == term {
                Text("Steam found nothing called \"\(searchedFor)\", or this network blocks it.")
                    .font(.cCallout).foregroundStyle(.secondary)
            }
        }
    }

    private func clear() {
        term = ""
        results = []
        searchedFor = ""
    }

    private func search() async {
        let query = term.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return clear() }
        searching = true
        results = await model.compatibility.search(query)
        searchedFor = term
        searching = false
    }
}

struct WillItRunRow: View {
    @Environment(AppModel.self) private var model
    let match: CompatibilityService.StoreMatch
    @State private var assessment: CompatibilityAssessment?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ArtworkImage(url: match.image)
                .frame(width: 120, height: 45)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(match.name).font(.cHeadline).lineLimit(1)
                    if let assessment {
                        VerdictPill(verdict: assessment.verdict)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                if let reason = assessment?.reasons.first {
                    Text(reason.text).font(.cCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if model.games.contains(where: { $0.id == match.id && $0.app.isInstalled }) {
                Text("Installed").font(.cCaption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
            } else {
                Button("Get in Steam") { model.install(appID: match.id) }
                    .buttonStyle(GlassButtonStyle())
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.05)))
        .task(id: match.id) { assessment = await model.assessOnline(match) }
    }
}
