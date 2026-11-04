// Draws Cellar's app icon (the Clean Glass mark on a black tile) into the asset catalog.
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
    NSColor(red: 0.071, green: 0.063, blue: 0.082, alpha: 1).setFill()
    path.fill()
    NSColor(white: 1, alpha: 0.14).setStroke()
    path.lineWidth = max(1, s / 256)
    path.stroke()
    // The Clean Glass mark, in a 100 by 100 space with y going up from the tile's bottom.
    let unit = tile.width / 100
    let pt = { (x: CGFloat, y: CGFloat) in NSPoint(x: tile.minX + x * unit, y: tile.maxY - y * unit) }
    let wine = NSBezierPath()
    wine.move(to: pt(33.5, 37))
    wine.line(to: pt(66.5, 37))
    wine.curve(to: pt(50, 57), controlPoint1: pt(66, 50), controlPoint2: pt(60, 57))
    wine.curve(to: pt(33.5, 37), controlPoint1: pt(40, 57), controlPoint2: pt(34, 50))
    wine.close()
    NSColor(red: 0.788, green: 0.188, blue: 0.302, alpha: 1).setFill()
    wine.fill()
    let glass = NSBezierPath()
    glass.move(to: pt(32, 19))
    glass.line(to: pt(68, 19))
    glass.curve(to: pt(50, 57), controlPoint1: pt(68.5, 44), controlPoint2: pt(61, 57))
    glass.curve(to: pt(32, 19), controlPoint1: pt(39, 57), controlPoint2: pt(31.5, 44))
    glass.close()
    glass.move(to: pt(50, 57))
    glass.line(to: pt(50, 77))
    glass.move(to: pt(37, 79))
    glass.line(to: pt(63, 79))
    // Thicker at tiny sizes, where a thin line would disappear.
    glass.lineWidth = unit * (px <= 32 ? 6 : 3.6)
    glass.lineCapStyle = .round
    glass.lineJoinStyle = .round
    NSColor.white.setStroke()
    glass.stroke()
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
