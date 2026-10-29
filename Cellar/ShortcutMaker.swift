import AppKit
import CellarKit

/// Makes `~/Applications/Cellar Games/<Game>.app`: a tiny app with the game's art as its icon
/// that opens `cellar://play/<appid>`, so a game can live in the Dock or Launchpad.
enum ShortcutMaker {
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/Cellar Games", directoryHint: .isDirectory)
    }

    static func create(for game: Game) async throws -> URL {
        let fm = FileManager.default
        let safeName = game.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let app = folder.appending(path: "\(safeName).app", directoryHint: .isDirectory)
        let contents = app.appending(path: "Contents", directoryHint: .isDirectory)
        try? fm.removeItem(at: app)
        try fm.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleIdentifier": "com.tigercommander131.cellar.shortcut.\(game.id)",
            "CFBundleName": game.name,
            "CFBundleDisplayName": game.name,
            "CFBundleExecutable": "launch",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "LSApplicationCategoryType": "public.app-category.games",
            // Opens Cellar and quits; it never needs a Dock icon of its own while running.
            "LSUIElement": true,
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appending(path: "Info.plist"))

        let script = contents.appending(path: "MacOS/launch")
        try "#!/bin/sh\nexec /usr/bin/open \"cellar://play/\(game.id)\"\n".write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        if let icon = await icon(for: game) {
            NSWorkspace.shared.setIcon(icon, forFile: app.path, options: [])
        }
        return app
    }

    /// The game's portrait art, cropped square into the macOS icon shape.
    static func icon(for game: Game) async -> NSImage? {
        guard let url = game.artwork?.capsule ?? game.artwork?.header,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let art = NSImage(data: data) else { return nil }
        let size: CGFloat = 1024
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let inset = size * (1 - 824 / 1024) / 2
        let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
        path.addClip()
        // Centre-crop the art to a square, favouring the top where logos usually are.
        let a = art.size
        let side = min(a.width, a.height)
        let source = NSRect(x: (a.width - side) / 2, y: a.height - side - (a.height - side) * 0.25, width: side, height: side)
        art.draw(in: tile, from: source, operation: .copy, fraction: 1)
        NSColor(white: 1, alpha: 0.15).setStroke()
        path.lineWidth = 6
        path.stroke()
        image.unlockFocus()
        return image
    }
}
