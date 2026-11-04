// Draws Cellar's app icon (a white tulip glass of red wine on a wine-red tile) into the asset catalog.
// Usage: swift scripts/render-icon.swift Cellar/Assets.xcassets/AppIcon.appiconset
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let sizes = [16, 32, 128, 256, 512]

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: 824/1024 tile, centred.
    let inset = s * (1 - 824.0 / 1024.0) / 2
    let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    let color = { (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) in NSColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a) }
    NSGradient(colors: [color(150, 28, 58, 1), color(46, 7, 21, 1)])!.draw(in: path, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [color(255, 255, 255, 0.14), color(255, 255, 255, 0)])!
        .draw(in: NSRect(x: tile.minX, y: tile.midY + tile.height * 0.1, width: tile.width, height: tile.height * 0.4), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    // A white tulip glass with tilted wine, in a 100 by 100 space with y going down.
    let unit = tile.width / 100
    let pt = { (x: CGFloat, y: CGFloat) in NSPoint(x: tile.minX + x * unit, y: tile.maxY - y * unit) }
    let bowl = NSBezierPath()
    bowl.move(to: pt(33, 12))
    bowl.line(to: pt(67, 12))
    bowl.curve(to: pt(50, 62), controlPoint1: pt(82, 34), controlPoint2: pt(72, 62))
    bowl.curve(to: pt(33, 12), controlPoint1: pt(28, 62), controlPoint2: pt(18, 34))
    bowl.close()
    NSColor.white.setFill()
    bowl.fill()
    NSGraphicsContext.saveGraphicsState()
    bowl.addClip()
    let wine = NSBezierPath()
    wine.move(to: pt(14, 36))
    wine.curve(to: pt(86, 30), controlPoint1: pt(38, 30), controlPoint2: pt(62, 37))
    wine.line(to: pt(86, 70))
    wine.line(to: pt(14, 70))
    wine.close()
    NSGradient(colors: [color(244, 66, 106, 1), color(176, 22, 60, 1)])!.draw(in: wine, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    let stem = NSBezierPath()
    stem.move(to: pt(46.5, 60))
    stem.line(to: pt(53.5, 60))
    stem.curve(to: pt(52, 83), controlPoint1: pt(52, 68), controlPoint2: pt(52, 76))
    stem.line(to: pt(48, 83))
    stem.curve(to: pt(46.5, 60), controlPoint1: pt(48, 76), controlPoint2: pt(48, 68))
    stem.close()
    NSColor.white.setFill()
    stem.fill()
    NSBezierPath(ovalIn: NSRect(x: pt(32, 0).x, y: pt(0, 89).y, width: 36 * unit, height: 7.5 * unit)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for size in sizes {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try! render(size * scale).write(to: out.appending(path: name))
        images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
    }
}
let json = try! JSONSerialization.data(withJSONObject: ["images": images, "info": ["author": "xcode", "version": 1]], options: [.prettyPrinted])
try! json.write(to: out.appending(path: "Contents.json"))
print("Rendered \(images.count) icons")
