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

/// The logo's glass, in a 100 by 100 space. A tulip bowl, a tapered stem and a flat foot.
private enum GlassShape {
    static func bowl(_ p: inout Path, _ t: (CGFloat, CGFloat) -> CGPoint) {
        p.move(to: t(33, 12))
        p.addLine(to: t(67, 12))
        p.addCurve(to: t(50, 62), control1: t(82, 34), control2: t(72, 62))
        p.addCurve(to: t(33, 12), control1: t(28, 62), control2: t(18, 34))
        p.closeSubpath()
    }

    /// A little tilted, so it looks like liquid. Clip it to the bowl.
    static func wine(_ p: inout Path, _ t: (CGFloat, CGFloat) -> CGPoint) {
        p.move(to: t(14, 36))
        p.addCurve(to: t(86, 30), control1: t(38, 30), control2: t(62, 37))
        p.addLine(to: t(86, 70))
        p.addLine(to: t(14, 70))
        p.closeSubpath()
    }

    static func base(_ p: inout Path, _ t: (CGFloat, CGFloat) -> CGPoint) {
        p.move(to: t(46.5, 60))
        p.addLine(to: t(53.5, 60))
        p.addCurve(to: t(52, 83), control1: t(52, 68), control2: t(52, 76))
        p.addLine(to: t(48, 83))
        p.addCurve(to: t(46.5, 60), control1: t(48, 76), control2: t(48, 68))
        p.closeSubpath()
        let a = t(32, 81.5), b = t(68, 89)
        p.addEllipse(in: CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y))
    }
}

/// The glass by itself, for large art.
struct GlassMark: View {
    var glass: Color = .white
    var wine: Color = Theme.wine

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 100
            let t = { (x: CGFloat, y: CGFloat) in CGPoint(x: x * scale, y: y * scale) }
            var bowl = Path()
            GlassShape.bowl(&bowl, t)
            var base = Path()
            GlassShape.base(&base, t)
            var liquid = Path()
            GlassShape.wine(&liquid, t)
            context.fill(bowl, with: .color(glass))
            context.fill(base, with: .color(glass))
            var inside = context
            inside.clip(to: bowl)
            inside.fill(liquid, with: .color(wine))
        }
    }
}

/// The app's icon, for the few places it appears inside the app.
struct AppMark: View {
    var size: CGFloat

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            // The icon file has empty margins, as macOS expects. This crops to the tile.
            .frame(width: size * 1.243, height: size * 1.243)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
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
    /// The glass as a solid shape, which macOS tints to suit the menu bar.
    static let cellarMenuBar: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            let scale = rect.width / 100
            let t = { (x: CGFloat, y: CGFloat) in CGPoint(x: x * scale, y: y * scale) }
            var solid = Path()
            GlassShape.bowl(&solid, t)
            GlassShape.base(&solid, t)
            NSColor.black.setFill()
            NSBezierPath(cgPath: solid.cgPath).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// A switch that reads clearly on Cellar's dark screens: white when on.
///
/// It takes a plain value, not a Binding. Whoever builds it reads that value in their own body, which
/// is what makes the screen redraw when it changes. With a Binding made from closures the read was
/// hidden, and switches only caught up when you left the screen and came back.
struct CellarSwitch: View {
    let title: String
    let isOn: Bool
    let set: (Bool) -> Void

    init(_ title: String, isOn: Bool, set: @escaping (Bool) -> Void) {
        self.title = title
        self.isOn = isOn
        self.set = set
    }

    var body: some View {
        Button { set(!isOn) } label: { SwitchShape(isOn: isOn) }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityAddTraits(.isToggle)
    }
}

/// The switch's picture alone, for rows where the whole row is the button.
struct SwitchShape: View {
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? Color.white : Color.white.opacity(0.18))
            .frame(width: 42, height: 24)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(isOn ? Color.black : Color.white)
                    .frame(width: 18, height: 18)
                    .padding(3)
            }
            .animation(.snappy(duration: 0.16), value: isOn)
            .contentShape(Rectangle())
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
