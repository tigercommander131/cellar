// Draws Cellar's app icon (a wine glass on a deep red rounded tile) into the asset catalog.
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
    NSGradient(colors: [NSColor(red: 0.66, green: 0.13, blue: 0.22, alpha: 1), NSColor(red: 0.26, green: 0.03, blue: 0.09, alpha: 1)])!
        .draw(in: path, angle: -90)
    NSColor(white: 1, alpha: 0.12).setStroke()
    path.lineWidth = max(1, s / 256)
    path.stroke()
    let config = NSImage.SymbolConfiguration(pointSize: tile.width * 0.5, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let glass = NSImage(systemSymbolName: "wineglass.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let g = glass.size
        glass.draw(in: NSRect(x: (s - g.width) / 2, y: (s - g.height) / 2, width: g.width, height: g.height))
    }
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
