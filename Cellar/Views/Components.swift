import CellarKit
import SwiftUI

/// The accent pill used for Set Up and Play.
struct PillButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? .title3.weight(.semibold) : .body.weight(.semibold))
            .padding(.horizontal, large ? 28 : 20)
            .padding(.vertical, large ? 11 : 8)
            .background(Capsule().fill(Color.accentColor.opacity(isEnabled ? 1 : 0.4)))
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Round secondary buttons next to Play.
struct CircleIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 38, height: 38)
                .background(Circle().fill(.white.opacity(0.12)))
                .overlay(Circle().strokeBorder(.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The app's mark: a wine glass on a deep red tile.
struct AppMark: View {
    var size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.62, green: 0.12, blue: 0.20), Color(red: 0.30, green: 0.04, blue: 0.10)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "wineglass.fill")
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
    }
}

/// Steam artwork with a quiet placeholder while it loads (or if Steam has none).
struct ArtworkImage: View {
    let url: URL?
    var fallbackTitle: String = ""

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                ZStack {
                    LinearGradient(colors: [Color(white: 0.18), Color(white: 0.11)], startPoint: .top, endPoint: .bottom)
                    Text(fallbackTitle)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
        }
    }
}

struct StatusDot: View {
    let on: Bool
    var body: some View {
        Circle()
            .fill(on ? Color.green : Color.secondary.opacity(0.5))
            .frame(width: 8, height: 8)
    }
}

extension GraphicsBackend {
    var shortName: String {
        switch self {
        case .d3dmetal: "D3DMetal"
        case .dxmt: "DXMT"
        case .wined3d: "WineD3D"
        }
    }
}

extension Int64 {
    var formattedBytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
