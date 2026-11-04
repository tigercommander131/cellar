import AppKit
import SwiftUI

/// Cellar's type: Sora, which ships with the app (SIL Open Font License, see Sora-OFL.txt).
extension Font {
    static func cellar(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Sora", size: size).weight(weight)
    }

    static let cCaption2 = Font.cellar(10)
    static let cCaption = Font.cellar(11.5)
    static let cCallout = Font.cellar(13)
    static let cBody = Font.cellar(14)
    static let cHeadline = Font.cellar(14, .semibold)
    static let cTitle3 = Font.cellar(17)
    static let cTitle2 = Font.cellar(21)
}

enum Theme {
    /// The ground behind everything: nearly black, so game art carries the colour.
    static let ground = Color(red: 0.027, green: 0.024, blue: 0.039)
    static let wine = Color(red: 0.788, green: 0.188, blue: 0.302)
    static let surface = Color.white.opacity(0.07)
    static let line = Color.white.opacity(0.12)
    static let secondaryText = Color.white.opacity(0.68)
    static let positive = Color(red: 0.494, green: 0.886, blue: 0.659)
}

/// The Clean Glass logo's parts, in a 100 by 100 space.
private enum GlassShape {
    static func bowl(_ p: inout Path, _ t: (CGFloat, CGFloat) -> CGPoint) {
        p.move(to: t(32, 19))
        p.addLine(to: t(68, 19))
        p.addCurve(to: t(50, 57), control1: t(68.5, 44), control2: t(61, 57))
        p.addCurve(to: t(32, 19), control1: t(39, 57), control2: t(31.5, 44))
        p.closeSubpath()
    }

    static func wine(_ p: inout Path, _ t: (CGFloat, CGFloat) -> CGPoint) {
        p.move(to: t(33.5, 37))
        p.addLine(to: t(66.5, 37))
        p.addCurve(to: t(50, 57), control1: t(66, 50), control2: t(60, 57))
        p.addCurve(to: t(33.5, 37), control1: t(40, 57), control2: t(34, 50))
        p.closeSubpath()
    }

    static func foot(_ p: inout Path, _ t: (CGFloat, CGFloat) -> CGPoint) {
        p.move(to: t(50, 57))
        p.addLine(to: t(50, 77))
        p.move(to: t(37, 79))
        p.addLine(to: t(63, 79))
    }
}

/// The glass by itself: a white outline holding red wine.
struct GlassMark: View {
    var line: Color = .white
    var wine: Color = Theme.wine

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 100
            let t = { (x: CGFloat, y: CGFloat) in CGPoint(x: x * scale, y: y * scale) }
            var fill = Path()
            GlassShape.wine(&fill, t)
            context.fill(fill, with: .color(wine))
            let stroke = StrokeStyle(lineWidth: 3.6 * scale, lineCap: .round, lineJoin: .round)
            var outline = Path()
            GlassShape.bowl(&outline, t)
            GlassShape.foot(&outline, t)
            context.stroke(outline, with: .color(line), style: stroke)
        }
    }
}

/// The app's mark: the glass on a black tile.
struct AppMark: View {
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(Color(red: 0.071, green: 0.063, blue: 0.082))
            .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).strokeBorder(.white.opacity(0.18)))
            .frame(width: size, height: size)
            .overlay { GlassMark().frame(width: size, height: size) }
    }
}

/// "cellar" in lowercase, as the app's name appears everywhere.
struct Wordmark: View {
    var size: CGFloat = 19

    var body: some View {
        Text("cellar")
            .font(.cellar(size, .heavy))
            .tracking(-size * 0.02)
            .accessibilityLabel("Cellar")
    }
}

extension NSImage {
    /// The glass as a menu bar icon, which macOS tints to suit the bar.
    static let cellarMenuBar: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            let scale = rect.width / 100
            let t = { (x: CGFloat, y: CGFloat) in CGPoint(x: x * scale, y: y * scale) }
            var outline = Path()
            GlassShape.bowl(&outline, t)
            GlassShape.foot(&outline, t)
            var fill = Path()
            GlassShape.wine(&fill, t)
            let ink = NSColor.black
            ink.setFill()
            NSBezierPath(cgPath: fill.cgPath).fill()
            ink.setStroke()
            let path = NSBezierPath(cgPath: outline.cgPath)
            path.lineWidth = 7.5 * scale
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// A switch that reads clearly on Cellar's dark screens: white when on.
struct CellarToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            // The label is only for VoiceOver: each row already says what the switch does.
            Capsule()
                .fill(configuration.isOn ? Color.white : Color.white.opacity(0.18))
                .frame(width: 42, height: 24)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(configuration.isOn ? Color.black : Color.white)
                        .frame(width: 18, height: 18)
                        .padding(3)
                }
                .animation(.snappy(duration: 0.16), value: configuration.isOn)
                .contentShape(Rectangle())
                .accessibilityLabel(configuration.label)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? [.isSelected] : [])
    }
}

/// The button everyone notices: Play, Resume, Save.
struct PillButtonStyle: ButtonStyle {
    var large = false
    var tint: Color = .white
    var text: Color = .black
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? .cellar(16, .bold) : .cellar(13, .bold))
            .padding(.horizontal, large ? 40 : 18)
            .frame(minHeight: large ? 52 : 38)
            .background(RoundedRectangle(cornerRadius: large ? 14 : 11, style: .continuous).fill(tint.opacity(isEnabled ? 1 : 0.35)))
            .foregroundStyle(text)
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }
}

/// Everything else you can press.
struct GlassButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? .cellar(14, .semibold) : .cellar(12.5, .semibold))
            .padding(.horizontal, large ? 22 : 13)
            .frame(minHeight: large ? 52 : 36)
            .background(RoundedRectangle(cornerRadius: large ? 14 : 10, style: .continuous).fill(.white.opacity(configuration.isPressed ? 0.24 : 0.1)))
            .overlay(RoundedRectangle(cornerRadius: large ? 14 : 10, style: .continuous).strokeBorder(.white.opacity(0.22)))
            .foregroundStyle(.white)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }
}
