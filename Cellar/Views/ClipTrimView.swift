import AppKit
import AVFoundation
import CellarKit
import SwiftUI

/// Watch a clip, cut it, and send it. The same screen in the Clips tab and in the overlay.
struct ClipEditorView: View {
    @Environment(AppModel.self) private var model
    /// In the overlay, the Mac's share menu would open underneath it, so sharing is by copying.
    var inOverlay = false
    let close: () -> Void
    @State private var clip: ClipItem
    @State private var player = AVPlayer()
    @State private var still: NSImage?
    @State private var duration: Double = 0
    @State private var start: Double = 0
    @State private var end: Double = 0
    @State private var position: Double = 0
    @State private var frames: [CGImage] = []
    @State private var playing = false
    @State private var busy: String?
    @State private var failure: String?
    @State private var shareAnchor: NSView?

    init(clip: ClipItem, inOverlay: Bool = false, close: @escaping () -> Void) {
        _clip = State(initialValue: clip)
        self.inOverlay = inOverlay
        self.close = close
    }

    private var isVideo: Bool { clip.kind == .video }
    private var isTrimmed: Bool { duration > 0 && (start > 0.05 || end < duration - 0.05) }

    var body: some View {
        VStack(spacing: 12) {
            header
            picture
            if isVideo {
                if duration > 0 {
                    TrimBar(duration: duration, frames: frames, start: $start, end: $end, position: position, scrub: seek)
                        .frame(height: inOverlay ? 44 : 58)
                } else {
                    ProgressView().controlSize(.small).frame(height: 44)
                }
                trimRow
            }
            actionRow
        }
        .task(id: clip.id) { await load() }
        .task(id: end) { await watchPlayback() }
        .onDisappear { player.pause() }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 12) {
            Button { finish() } label: { Label("Back", systemImage: "chevron.left") }
                .buttonStyle(GlassButtonStyle())
                .keyboardShortcut(.cancelAction)
            VStack(alignment: .leading, spacing: 1) {
                Text(clip.game).font(.cellar(14, .bold)).lineLimit(1)
                Text("\(clip.date.formatted(date: .abbreviated, time: .shortened)), \(clip.size.formattedBytes)")
                    .font(.cCaption).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            Spacer()
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(GlassButtonStyle())
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(neighbour(-1) == nil)
                .help("Previous clip")
                .accessibilityLabel("Previous clip")
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(GlassButtonStyle())
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(neighbour(1) == nil)
                .help("Next clip")
                .accessibilityLabel("Next clip")
        }
    }

    @ViewBuilder private var picture: some View {
        Group {
            if isVideo {
                ClipVideoView(player: player)
                    .overlay {
                        if !playing {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 54))
                                .foregroundStyle(.white.opacity(0.9))
                                .shadow(radius: 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { togglePlaying() }
            } else if let still {
                Image(nsImage: still).resizable().scaledToFit()
            } else {
                Color.white.opacity(0.05)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var trimRow: some View {
        HStack(spacing: 8) {
            Button { togglePlaying() } label: {
                Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill").frame(minWidth: 62)
            }
            .buttonStyle(GlassButtonStyle())
            .keyboardShortcut(.space, modifiers: [])
            // Only lengths shorter than the clip do anything.
            let lengths = [10, 15, 30].filter { Double($0) < duration - 1 }
            if !lengths.isEmpty {
                Text("Keep the last").font(.cCaption).foregroundStyle(Theme.secondaryText).padding(.leading, 6)
                ForEach(lengths, id: \.self) { seconds in
                    Button("\(seconds)s") { keepLast(seconds) }.buttonStyle(GlassButtonStyle())
                }
            }
            if isTrimmed {
                Button("Reset") { reset() }.buttonStyle(GlassButtonStyle())
            }
            Spacer()
            Text(isTrimmed ? "Keeping \(time(end - start)) of \(time(duration))" : time(duration))
                .font(.cCallout).monospacedDigit().foregroundStyle(.white.opacity(0.82))
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            if let failure {
                Text(failure).font(.cCaption).foregroundStyle(.orange).lineLimit(2)
            } else if let busy {
                ProgressView().controlSize(.small)
                Text(busy).font(.cCaption).foregroundStyle(Theme.secondaryText)
            } else if isVideo, !inOverlay {
                Text("Trimming keeps your original.").font(.cCaption).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Button { reveal() } label: { Image(systemName: "folder") }
                .buttonStyle(GlassButtonStyle()).help("Show in Finder").accessibilityLabel("Show in Finder")
            Button { trash() } label: { Image(systemName: "trash") }
                .buttonStyle(GlassButtonStyle()).help("Move to Trash").accessibilityLabel("Move to Trash")
            if isVideo {
                Button("Make Small Copy") { Task { await makeSmall() } }
                    .buttonStyle(GlassButtonStyle())
                    .help("Under 10 MB, for apps that limit file size")
                if isTrimmed {
                    Button("Save Trim") { Task { await saveTrim() } }.buttonStyle(GlassButtonStyle())
                }
            }
            Button("Copy") { Task { await copy() } }
                .buttonStyle(inOverlay ? AnyButtonStyle(PillButtonStyle()) : AnyButtonStyle(GlassButtonStyle()))
                .help("Paste it into Discord, Messages or anywhere else")
            if !inOverlay {
                Button("Share") { Task { await share() } }
                    .buttonStyle(PillButtonStyle())
                    .background(ShareAnchor { shareAnchor = $0 })
            }
        }
        .disabled(busy != nil)
    }

    // MARK: Loading and playing

    private func load() async {
        player.pause()
        playing = false
        failure = nil
        start = 0
        end = 0
        position = 0
        duration = 0
        frames = []
        still = nil
        guard isVideo else {
            still = NSImage(contentsOf: clip.url)
            return
        }
        let asset = AVURLAsset(url: clip.url)
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        guard let length = try? await asset.load(.duration).seconds, length > 0 else {
            failure = "Couldn't read this clip."
            return
        }
        duration = length
        end = length
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 135)
        var images: [CGImage] = []
        for index in 0..<12 {
            if let image = try? await generator.image(at: seconds(length * (Double(index) + 0.5) / 12)).image { images.append(image) }
        }
        frames = images
    }

    /// Stops at the end of the selection, however playing started, and keeps the playhead moving.
    private func watchPlayback() async {
        while !Task.isCancelled {
            let now = player.currentTime().seconds
            if now.isFinite { position = now }
            if player.rate > 0, end > 0, now >= end { player.pause() }
            playing = player.rate > 0
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    private func togglePlaying() {
        guard isVideo else { return }
        if player.rate > 0 {
            player.pause()
            return
        }
        let now = player.currentTime().seconds
        if now < start || now >= end - 0.05 { seek(start) }
        player.play()
    }

    private func seek(_ to: Double) {
        player.seek(to: seconds(to), toleranceBefore: .zero, toleranceAfter: .zero)
        position = to
    }

    private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

    private func time(_ value: Double) -> String { String(format: "%d:%02d", Int(max(value, 0)) / 60, Int(max(value, 0)) % 60) }

    private func keepLast(_ length: Int) {
        let range = ClipEditor.lastPart(seconds: Double(length), of: duration)
        start = range.start
        end = range.end
        seek(start)
    }

    private func reset() {
        start = 0
        end = duration
    }

    // MARK: Moving between clips

    private func neighbour(_ delta: Int) -> ClipItem? {
        guard let index = model.clips.firstIndex(where: { $0.id == clip.id }) else { return nil }
        let next = index + delta
        return model.clips.indices.contains(next) ? model.clips[next] : nil
    }

    private func step(_ delta: Int) {
        if let next = neighbour(delta) { clip = next }
    }

    private func finish() {
        player.pause()
        close()
    }

    // MARK: Saving and sending

    /// The selected part as its own file, or the clip as it is if nothing's been cut.
    private func currentFile() async throws -> URL {
        guard isVideo, isTrimmed else { return clip.url }
        busy = "Saving your trim…"
        defer { busy = nil }
        let output = ClipEditor.copyURL(for: clip.url, suffix: "trimmed")
        try await ClipEditor.trim(clip.url, from: start, to: end, saveTo: output)
        return output
    }

    private func saveTrim() async {
        do {
            let file = try await currentFile()
            show(file)
            model.tell("Trim saved. Your original is still there.", systemImage: "scissors")
        } catch {
            failure = error.localizedDescription
        }
    }

    private func copy() async {
        do {
            let file = try await currentFile()
            if file != clip.url { show(file) }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([file as NSURL])
            model.tell("Copied. Paste it into Discord, Messages or anywhere else.", systemImage: "doc.on.doc")
        } catch {
            failure = error.localizedDescription
        }
    }

    private func share() async {
        do {
            let file = try await currentFile()
            if file != clip.url { show(file) }
            guard let shareAnchor else { return }
            NSSharingServicePicker(items: [file]).show(relativeTo: .zero, of: shareAnchor, preferredEdge: .minY)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func makeSmall() async {
        failure = nil
        if !isTrimmed, clip.size <= Int64(ClipEditor.smallLimit) {
            model.tell("This one's already under 10 MB.", systemImage: "checkmark")
            return
        }
        do {
            let source = try await currentFile()
            busy = "Making a small copy…"
            defer { busy = nil }
            player.pause()
            let output = ClipEditor.copyURL(for: clip.url, suffix: "small")
            let size = try await ClipEditor.makeSmall(source, saveTo: output)
            show(output)
            let label = Int64(size).formattedBytes
            model.tell(size <= ClipEditor.smallLimit
                ? "Small copy ready, \(label). Copy or Share it."
                : "That's as small as it goes, \(label). Trim it shorter to get under 10 MB.", systemImage: "arrow.down.circle")
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Moves to a file that's just been saved, so the next Copy or Share sends that one.
    private func show(_ file: URL) {
        let item = ClipLibrary.item(at: file)
        model.refreshClips()
        if let item { clip = item }
    }

    private func reveal() {
        model.overlay.hide()
        NSWorkspace.shared.activateFileViewerSelecting([clip.url])
    }

    private func trash() {
        player.pause()
        let next = neighbour(1) ?? neighbour(-1)
        model.delete(clip)
        if let next { clip = next } else { close() }
    }
}

/// Lets a button use either style, depending on where it's shown.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// Gives the Mac's share menu a place to open from.
struct ShareAnchor: NSViewRepresentable {
    let found: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { found(view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// Just the picture. SwiftUI's own `VideoPlayer` crashes the app inside Apple's code when it's created
/// (`_AVKit_SwiftUI`, seen on macOS 26 in 2.1.0), so this draws with a plain player layer instead.
struct ClipVideoView: NSViewRepresentable {
    let player: AVPlayer
    /// Fills the space, cropping if it has to, rather than fitting inside it.
    var fills = false

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = fills ? .resizeAspectFill : .resizeAspect
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
    }

    final class PlayerLayerView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = playerLayer
        }

        required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    }
}

/// A strip of frames with a handle at each end and a playhead. The part outside the handles is dimmed.
/// Click anywhere on it to jump there.
struct TrimBar: View {
    let duration: Double
    let frames: [CGImage]
    @Binding var start: Double
    @Binding var end: Double
    var position: Double = 0
    let scrub: (Double) -> Void

    private let handle: CGFloat = 14
    /// The shortest clip the handles allow, in seconds.
    private let shortest = 0.5

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let startX = CGFloat(start / duration) * width
            let endX = CGFloat(end / duration) * width
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(frames.indices, id: \.self) { index in
                        Image(decorative: frames[index], scale: 1)
                            .resizable().scaledToFill()
                            .frame(width: width / CGFloat(max(frames.count, 1)), height: geometry.size.height)
                            .clipped()
                    }
                }
                .frame(width: width, height: geometry.size.height, alignment: .leading)
                .background(Color.white.opacity(0.08))
                .contentShape(Rectangle())
                .onTapGesture { location in
                    scrub(min(max(Double(location.x / width) * duration, start), end))
                }
                Color.black.opacity(0.66).frame(width: max(startX, 0)).allowsHitTesting(false)
                Color.black.opacity(0.66).frame(width: max(width - endX, 0)).offset(x: endX).allowsHitTesting(false)
                RoundedRectangle(cornerRadius: 5).strokeBorder(.white, lineWidth: 3)
                    .frame(width: max(endX - startX, 0)).offset(x: startX)
                    .allowsHitTesting(false)
                Rectangle().fill(.white).frame(width: 2)
                    .offset(x: min(max(CGFloat(position / duration) * width, 0), width - 2))
                    .allowsHitTesting(false)
                grip.offset(x: startX - handle / 2)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim")).onChanged { value in
                        start = min(max(Double(value.location.x / width) * duration, 0), end - shortest)
                        scrub(start)
                    })
                    .accessibilityLabel("Start of clip")
                grip.offset(x: endX - handle / 2)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim")).onChanged { value in
                        end = max(min(Double(value.location.x / width) * duration, duration), start + shortest)
                        scrub(end)
                    })
                    .accessibilityLabel("End of clip")
            }
            .coordinateSpace(name: "trim")
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var grip: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(.white)
            .frame(width: handle)
            .overlay(Capsule().fill(.black.opacity(0.6)).frame(width: 2, height: 20))
            .contentShape(Rectangle())
    }
}
