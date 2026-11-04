import CellarKit
import SwiftUI

/// Round secondary buttons next to Play.
struct CircleIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.cellar(15, .medium))
                .frame(width: 38, height: 38)
                .background(Circle().fill(.white.opacity(0.12)))
                .overlay(Circle().strokeBorder(.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
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
                        .font(.cHeadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.72))
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
