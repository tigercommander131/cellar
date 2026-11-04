import AVFoundation
import CellarKit
import SwiftUI

/// Every clip and screenshot, with or without a game running. Click one to watch, trim or send it.
/// Drag one straight into Discord or Messages.
struct ClipsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var game: String?

    private var games: [String] { Array(Set(model.clips.map(\.game))).sorted() }
    private var shown: [ClipItem] { game.map { name in model.clips.filter { $0.game == name } } ?? model.clips }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("Clips").font(.cellar(32, .heavy))
                    Text(summary).font(.cCallout).foregroundStyle(Theme.secondaryText)
                    Spacer()
                    Button("Show in Finder") { model.showClipsFolder() }.buttonStyle(GlassButtonStyle())
                }
                if games.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            chip("All games", game == nil) { game = nil }
                            ForEach(games, id: \.self) { name in
                                chip(name, game == name) { game = name }
                            }
                        }
                    }
                }
                if shown.isEmpty {
                    empty
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 18)], alignment: .leading, spacing: 22) {
                        ForEach(shown) { ClipTile(clip: $0) }
                    }
                }
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 18)
        }
        .scrollIndicators(.hidden)
        .onAppear { model.refreshClips() }
    }

    private var summary: String {
        let size = model.clips.reduce(Int64(0)) { $0 + $1.size }
        return model.clips.isEmpty ? "" : "\(model.clips.count) saved, \(size.formattedBytes)"
    }

    private func chip(_ title: String, _ on: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title)
                .font(.cellar(12.5, .semibold))
                .foregroundStyle(on ? .black : .white)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Capsule().fill(on ? .white : .white.opacity(0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 44, weight: .light)).foregroundStyle(.white.opacity(0.4))
            Text("Nothing saved yet").font(.cellar(18, .bold))
            Text("Press \(OverlayController.clipHotkeyLabel) in a game to save what just happened. It shows up here.")
                .font(.cBody).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 340)
    }
}

struct ClipTile: View {
    @Environment(AppModel.self) private var model
    let clip: ClipItem
    @State private var hovering = false
    @State private var length: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ClipThumbnail(clip: clip)
                .overlay {
                    if hovering {
                        ZStack {
                            Color.black.opacity(0.35)
                            Image(systemName: clip.kind == .video ? "play.circle.fill" : "eye.circle.fill")
                                .font(.system(size: 44)).foregroundStyle(.white)
                        }
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let length {
                        Text(length)
                            .font(.cellar(11, .bold)).monospacedDigit()
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(.black.opacity(0.72)))
                            .padding(8)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .scaleEffect(hovering ? 1.015 : 1)
            Text(clip.game).font(.cHeadline).lineLimit(1)
            Text("\(clip.date.formatted(date: .abbreviated, time: .shortened)), \(clip.size.formattedBytes)")
                .font(.cCaption).foregroundStyle(Theme.secondaryText).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.viewingClip = clip }
        .onHover { over in withAnimation(.snappy(duration: 0.14)) { hovering = over } }
        .onDrag { NSItemProvider(contentsOf: clip.url) ?? NSItemProvider() }
        .help("Click to open. Drag into Discord or Messages to send it.")
        .contextMenu {
            Button("Open") { model.viewingClip = clip }
            Button("Copy") { model.copy(clip) }
            Button("Show in Finder") { model.reveal(clip) }
            Divider()
            Button("Move to Trash") { model.delete(clip) }
        }
        .task(id: clip.id) {
            guard clip.kind == .video, let seconds = try? await AVURLAsset(url: clip.url).load(.duration).seconds, seconds.isFinite else { return }
            length = String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
        }
    }
}
