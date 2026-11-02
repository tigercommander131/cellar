import AppKit
import Foundation

/// What Spotify is playing.
public struct SpotifyState: Sendable, Equatable {
    public var isPlaying = false
    public var trackID: String?
    public var name: String?
    public var artist: String?
    public var album: String?
    /// Seconds.
    public var duration: Double = 0
    public var position: Double = 0
    public var artwork: URL?
    /// 0...100, nil until read from the app.
    public var volume: Int?
    public var updated = Date()

    public init() {}

    public var hasTrack: Bool { name?.isEmpty == false }

    /// From Spotify's `PlaybackStateChanged` notification. It has no cover art or volume.
    public init(notification info: [AnyHashable: Any]) {
        isPlaying = info["Player State"] as? String == "Playing"
        trackID = info["Track ID"] as? String
        name = info["Name"] as? String
        artist = info["Artist"] as? String
        album = info["Album"] as? String
        duration = ((info["Duration"] as? NSNumber)?.doubleValue ?? 0) / 1000
        position = (info["Playback Position"] as? NSNumber)?.doubleValue ?? 0
    }
}

/// Talks to the Spotify app on this Mac. Reading what's playing comes free from its notifications;
/// anything else is AppleScript, which macOS asks permission for once.
public enum SpotifyPlayer {
    public static let bundleID = "com.spotify.client"

    public static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    public static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    public enum Permission: Sendable { case allowed, wouldAsk, denied, notRunning }

    /// `ask` shows macOS's question if it hasn't been answered, and waits for the answer.
    public static func permission(ask: Bool = false) -> Permission {
        guard isRunning else { return .notRunning }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return .denied }
        switch AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask) {
        case noErr: return .allowed
        case OSStatus(errAEEventWouldRequireUserConsent): return .wouldAsk
        case OSStatus(procNotFound): return .notRunning
        default: return .denied
        }
    }

    public enum Command: Sendable, Equatable {
        case playPause, next, previous
        case volume(Int)
        case seek(Double)

        var script: String {
            switch self {
            case .playPause: "playpause"
            case .next: "next track"
            case .previous: "previous track"
            case .volume(let level): "set sound volume to \(min(max(level, 0), 100))"
            case .seek(let seconds): "set player position to \(max(seconds, 0))"
            }
        }
    }

    public static func send(_ command: Command) throws {
        _ = try run(command.script)
    }

    /// nil when Spotify isn't running: AppleScript would open it otherwise.
    public static func read() throws -> SpotifyState? {
        guard isRunning else { return nil }
        return parse(try run(readScript))
    }

    private static let separator = "\u{1F}"

    private static let readScript = """
    set sep to ASCII character 31
    set s to player state as string
    set v to sound volume
    if s is "stopped" then return s & sep & v
    set p to player position
    tell current track to return s & sep & v & sep & p & sep & id & sep & name & sep & artist & sep & album & sep & duration & sep & artwork url
    """

    static func parse(_ output: String) -> SpotifyState {
        let fields = output.trimmingCharacters(in: .newlines).components(separatedBy: separator)
        var state = SpotifyState()
        state.isPlaying = fields.first == "playing"
        if fields.count > 1 { state.volume = Int(fields[1]) }
        guard fields.count >= 9 else { return state }
        // AppleScript may write decimals with a comma in some regions.
        state.position = Double(fields[2].replacingOccurrences(of: ",", with: ".")) ?? 0
        state.trackID = fields[3]
        state.name = fields[4]
        state.artist = fields[5]
        state.album = fields[6]
        state.duration = (Double(fields[7].replacingOccurrences(of: ",", with: ".")) ?? 0) / 1000
        state.artwork = URL(string: fields[8])
        return state
    }

    /// `osascript` rather than NSAppleScript, which isn't safe off the main thread and could hang the
    /// app. macOS still treats these as coming from Cellar.
    private static func run(_ body: String) throws -> String {
        let script = "tell application id \"\(bundleID)\"\n\(body)\nend tell"
        let result = try Shell.run("/usr/bin/osascript", ["-e", script])
        guard result.status == 0 else { throw CellarError(result.output) }
        return result.output
    }
}

/// Spotify's notifications. Cellar is in the background during a game, when macOS would normally hold
/// these back, so this asks for them to be delivered right away.
public final class SpotifyWatcher: NSObject, @unchecked Sendable {
    private let handler: @Sendable @MainActor (SpotifyState) -> Void

    public init(handler: @escaping @Sendable @MainActor (SpotifyState) -> Void) {
        self.handler = handler
        super.init()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(changed(_:)),
                                                            name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
                                                            object: nil, suspensionBehavior: .deliverImmediately)
    }

    deinit { DistributedNotificationCenter.default().removeObserver(self) }

    @objc private func changed(_ notification: Notification) {
        let state = SpotifyState(notification: notification.userInfo ?? [:])
        let handler = self.handler
        Task { @MainActor in handler(state) }
    }
}
