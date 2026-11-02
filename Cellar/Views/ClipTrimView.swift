import AVFoundation
import CellarKit
import SwiftUI

/// Picks the part of a clip to keep. Saves a new file and leaves the original alone.
struct ClipTrimView: View {
    @Environment(AppModel.self) private var model
    let clip: ClipItem
    let close: () -> Void
    @State private var player: AVPlayer
    @State private var duration: Double = 0
    @State private var start: Double = 0
    @State private var end: Double = 0
    @State private var frames: [CGImage] = []
    @State private var saving = false
    @State private var failure: String?
    @State private var playing = false

    init(clip: ClipItem, close: @escaping () -> Void) {
        self.clip = clip
        self.close = close
        _player = State(initialValue: AVPlayer(url: clip.url))
    }

    var body: some View {
        VStack(spacing: 14) {
            ClipVideoView(player: player)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { togglePlaying() }
                .overlay {
                    if !playing {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 54))
                            .foregroundStyle(.white.opacity(0.85))
                            .shadow(radius: 8)
                            .allowsHitTesting(false)
                    }
                }
            if duration > 0 {
                TrimBar(duration: duration, frames: frames, start: $start, end: $end) { player.seek(to: seconds($0), toleranceBefore: .zero, toleranceAfter: .zero) }
                    .frame(height: 56)
            } else {
                ProgressView().controlSize(.small).frame(height: 56)
            }
            HStack(spacing: 8) {
                // Only lengths shorter than the clip do anything.
                let lengths = [10, 15, 30].filter { Double($0) < duration }
                if !lengths.isEmpty {
                    Text("Keep the last").font(.callout).foregroundStyle(.white.opacity(0.75))
                    ForEach(lengths, id: \.self) { seconds in
                        Button("\(seconds)s") { keepLast(seconds) }
                            .buttonStyle(GlassButtonStyle())
                    }
                }
                Spacer()
                Text("Keeping \(time(max(end - start, 0))) of \(time(duration))").font(.callout).monospacedDigit().foregroundStyle(.white.opacity(0.75))
            }
            HStack(spacing: 12) {
                if let failure { Text(failure).font(.callout).foregroundStyle(.orange) }
                Spacer()
                Button { togglePlaying() } label: { Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill") }
                    .buttonStyle(GlassButtonStyle())
                Button("Cancel", action: finish).buttonStyle(GlassButtonStyle())
                Button(saving ? "Saving…" : "Save as New Clip") { save() }
                    .buttonStyle(PillButtonStyle())
                    .disabled(saving || duration == 0 || end - start < 0.5)
            }
        }
        .task { await load() }
        // Stops at the end of the selection, however playing started.
        .task(id: end) {
            while !Task.isCancelled {
                if player.rate > 0, player.currentTime().seconds >= end { player.pause() }
                playing = player.rate > 0
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .onDisappear { player.pause() }
    }

    private func seconds(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }

    private func time(_ value: Double) -> String { String(format: "%d:%02d", Int(value) / 60, Int(value) % 60) }

    private func load() async {
        let asset = AVURLAsset(url: clip.url)
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
        for index in 0..<10 {
            if let image = try? await generator.image(at: seconds(length * (Double(index) + 0.5) / 10)).image { images.append(image) }
        }
        frames = images
    }

    /// Plays from where it is, or from the start of the selection if it's outside it.
    private func togglePlaying() {
        if player.rate > 0 {
            player.pause()
            return
        }
        let now = player.currentTime().seconds
        if now < start || now >= end - 0.05 {
            player.seek(to: seconds(start), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
    }

    private func keepLast(_ length: Int) {
        let range = ClipEditor.lastPart(seconds: Double(length), of: duration)
        start = range.start
        end = range.end
        player.seek(to: seconds(start), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func save() {
        saving = true
        failure = nil
        player.pause()
        let source = clip.url
        let output = ClipEditor.trimmedURL(for: source)
        let from = start
        let to = end
        Task {
            do {
                try await ClipEditor.trim(source, from: from, to: to, saveTo: output)
                model.refreshClips()
                model.overlay.showHUD("Trimmed clip saved", systemImage: "scissors")
                close()
            } catch {
                failure = error.localizedDescription
                saving = false
            }
        }
    }

    private func finish() {
        player.pause()
        close()
    }
}

/// Just the picture. SwiftUI's own `VideoPlayer` crashes the app inside Apple's code when it's created
/// (`_AVKit_SwiftUI`, seen on macOS 26 in 2.1.0), so this draws with a plain player layer instead.
struct ClipVideoView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
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

/// A strip of frames with a handle at each end. The part outside the handles is dimmed.
struct TrimBar: View {
    let duration: Double
    let frames: [CGImage]
    @Binding var start: Double
    @Binding var end: Double
    let scrub: (Double) -> Void

    private let handle: CGFloat = 12
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
                Color.black.opacity(0.62).frame(width: max(startX, 0))
                Color.black.opacity(0.62).frame(width: max(width - endX, 0)).offset(x: endX)
                RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 3)
                    .frame(width: max(endX - startX, 0)).offset(x: startX)
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
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.accentColor)
            .frame(width: handle)
            .overlay(Capsule().fill(.white).frame(width: 2, height: 22))
            .contentShape(Rectangle())
    }
}
