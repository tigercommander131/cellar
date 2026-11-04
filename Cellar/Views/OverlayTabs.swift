import AVFoundation
import CellarKit
import SwiftUI

// MARK: Home

struct OverlayHomeTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 16) {
                NowPlayingCard()
                OverlayQuickActions()
                OverlayVitals()
            }
            VStack(spacing: 16) {
                OverlayCard(title: "Friends") {
                    let friends = Array((model.friendsInGame + model.friendsOnline).prefix(7))
                    if friends.isEmpty {
                        Text(friendsEmptyText).font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(friends) { OverlayFriendRow(friend: $0, compact: true) }
                    if model.friendsInGame.count + model.friendsOnline.count > friends.count {
                        Button("See all \(model.friendsInGame.count + model.friendsOnline.count)") { model.overlayTab = .friends }
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
                if SpotifyPlayer.isRunning {
                    OverlayCard(title: "Music") {
                        if model.spotify.hasTrack {
                            MiniPlayer()
                        } else {
                            Button("Open the Music tab") { model.overlayTab = .music }
                                .buttonStyle(.link)
                                .font(.callout)
                        }
                    }
                }
                OverlayCard(title: "Latest clips") {
                    let latest = Array(model.clips.prefix(2))
                    if latest.isEmpty {
                        Text("Nothing saved yet. Turn Clips on, then press \(OverlayController.clipHotkeyLabel) after something good happens.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 10) {
                            ForEach(latest) { ClipThumbnail(clip: $0).onTapGesture { model.overlayTab = .clips } }
                        }
                    }
                }
            }
            .frame(width: 360)
        }
    }

    private var friendsEmptyText: String {
        if model.steamOffline { return "Steam is offline on this network, so friends are hidden for now." }
        return model.friendsLoaded ? "None of your friends are online." : "Checking who's on…"
    }
}

struct NowPlayingCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let game = model.runningGame
        ZStack(alignment: .bottomLeading) {
            // A wine-coloured wash shows through if there's no art at all, rather than a big black box.
            LinearGradient(colors: [Color(red: 0.32, green: 0.06, blue: 0.13), Color(red: 0.08, green: 0.05, blue: 0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay {
                    AsyncImage(url: game?.artwork?.hero ?? game?.artwork?.header) { phase in
                        if case .success(let image) = phase { image.resizable().scaledToFill() }
                    }
                }
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    AsyncImage(url: game?.artwork?.logo) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFit().frame(maxWidth: 300, maxHeight: 84, alignment: .leading)
                        } else {
                            Text(game?.name ?? "Cellar").font(.system(size: 30, weight: .heavy))
                        }
                    }
                    if let game, let verdict = model.verdicts[game.id]?.verdict {
                        VerdictPill(verdict: verdict)
                    }
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    HStack(spacing: 22) {
                        stat("This session", sessionText)
                        stat("All time in Cellar", totalText)
                    }
                }
            }
            .padding(20)
        }
        .frame(minHeight: 220, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.1)))
    }

    private var sessionText: String {
        guard let game = model.runningGame, let start = model.sessionStarts[game.id] else { return "–" }
        return AppModel.playTime(Date().timeIntervalSince(start))
    }

    private var totalText: String {
        guard let game = model.runningGame else { return "–" }
        let current = model.sessionStarts[game.id].map { Date().timeIntervalSince($0) } ?? 0
        return AppModel.playTime(model.totalPlayed(game.id) + current)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value).font(.title3.weight(.bold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.65))
        }
    }
}

struct OverlayQuickActions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            if model.clipsRecording {
                action("Save clip", "Last \(model.clipLengthLabel)", "record.circle.fill", tint: .red, busy: model.savingClip) { model.saveClip() }
            } else {
                action("Turn on Clips", "Stops with the game", "record.circle", tint: .white, busy: model.clipsStarting) { model.setClipsRecording(true) }
            }
            action("Screenshot", "Saved to Clips", "camera.fill", tint: .white) { model.takeScreenshot() }
            action("Invite friends", inviteDetail, "person.badge.plus", tint: .white) { model.overlayTab = .friends }
            action("Show Steam", "Opens its window", "gamecontroller.fill", tint: .white) {
                model.overlay.hide()
                model.openSteam()
            }
        }
    }

    private var inviteDetail: String {
        if model.steamOffline { return "Needs Steam online" }
        return model.ownLobby != nil || model.ownConnect != nil ? "Friends can join you" : "Host a lobby first"
    }

    private func action(_ title: String, _ detail: String, _ icon: String, tint: Color, busy: Bool = false, run: @escaping () -> Void) -> some View {
        OverlayActionButton(title: title, detail: detail, icon: icon, tint: tint, busy: busy, run: run)
    }
}

struct OverlayActionButton: View {
    let title: String
    let detail: String
    let icon: String
    let tint: Color
    var busy = false
    let run: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: run) {
            VStack(alignment: .leading, spacing: 10) {
                if busy {
                    ProgressView().controlSize(.small).frame(height: 22)
                } else {
                    Image(systemName: icon).font(.system(size: 19, weight: .semibold)).foregroundStyle(tint).frame(height: 22)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.bold)).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(hovering ? 0.14 : 0.07)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(hovering ? 0.25 : 0.1)))
            .contentShape(Rectangle())
            .scaleEffect(hovering ? 1.015 : 1)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .onHover { over in withAnimation(.snappy(duration: 0.14)) { hovering = over } }
    }
}

/// A row of the numbers that matter, and the volume.
struct OverlayVitals: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sample = model.stats.last
        HStack(spacing: 12) {
            StatTile(title: "Heat", value: sample?.thermal.title ?? "–", color: heatColor(sample?.thermal))
            StatTile(title: "Game CPU", value: sample.map { "\(Int($0.gameCPU * 100))%" } ?? "–",
                     history: model.stats.map(\.gameCPU), maximum: max(model.stats.map(\.gameCPU).max() ?? 1, 0.2))
            StatTile(title: "Game memory", value: gameMemoryText(sample), history: model.stats.map(\.memoryUsed))
            VolumeTile()
        }
        .frame(height: 104)
    }

    private func heatColor(_ level: ThermalLevel?) -> Color {
        switch level {
        case .warm: .orange
        case .hot, .critical: .red
        default: .green
        }
    }
}

func gameMemoryText(_ sample: SystemSample?) -> String {
    guard let bytes = sample?.gameMemoryBytes, bytes > 0 else { return "–" }
    return Int64(bytes).formattedBytes
}

struct StatTile: View {
    let title: String
    let value: String
    var detail: String?
    var color: Color = .white
    var history: [Double]?
    var maximum: Double = 1

    var body: some View {
        ZStack(alignment: .bottom) {
            if let history {
                Sparkline(values: history, maximum: maximum).frame(maxHeight: 44).opacity(0.9)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                Text(value).font(.title2.weight(.bold)).monospacedDigit().foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.07)))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.1)))
    }
}

struct VolumeTile: View {
    @State private var level: Float? = SystemVolume.level

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mac volume").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
            if let level {
                Text("\(Int((level * 100).rounded()))%").font(.title2.weight(.bold)).monospacedDigit()
                Slider(value: Binding(get: { Double(self.level ?? 0) }, set: { new in
                    self.level = Float(new)
                    SystemVolume.level = Float(new)
                }), in: 0...1)
                .controlSize(.small)
                .labelsHidden()
            } else {
                Text("Set on this output").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .onAppear { level = SystemVolume.level }
    }
}

// MARK: Friends

struct OverlayFriendsTab: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search friends", text: $search).textFieldStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: 300)
                .background(Capsule().fill(.white.opacity(0.09)))
                Text(lobbyStatus).font(.callout).foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button { Task { await model.refreshFriends() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(GlassButtonStyle())
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if model.steamOffline {
                        OverlayCard {
                            Label("Steam is offline on this network. Join and Invite come back when it's online.", systemImage: "wifi.slash")
                                .font(.callout)
                        }
                    } else if !model.friendsLoaded {
                        HStack { ProgressView().controlSize(.small); Text("Checking who's on…").foregroundStyle(.secondary) }
                    }
                    section("In this game", sameGame)
                    section("Playing now", otherGames)
                    section("Online", filtered(model.friendsOnline))
                    if model.friendsLoaded, !model.steamOffline, sameGame.isEmpty, otherGames.isEmpty, filtered(model.friendsOnline).isEmpty {
                        Text(search.isEmpty ? "None of your friends are online." : "No friends match that.").foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var sameGame: [SteamFriend] {
        filtered(model.friendsInGame).filter { $0.appID != nil && $0.appID == model.runningGame?.id }
    }

    private var otherGames: [SteamFriend] {
        filtered(model.friendsInGame).filter { $0.appID == nil || $0.appID != model.runningGame?.id }
    }

    private func filtered(_ friends: [SteamFriend]) -> [SteamFriend] {
        search.isEmpty ? friends : friends.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var lobbyStatus: String {
        if model.ownLobby != nil || model.ownConnect != nil { return "Friends can join you" }
        if model.ownApp != nil { return "Host a lobby in the game to invite friends" }
        return ""
    }

    @ViewBuilder private func section(_ title: String, _ friends: [SteamFriend]) -> some View {
        if !friends.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(title.uppercased())  \(friends.count)")
                    .font(.caption.weight(.bold)).tracking(1.1).foregroundStyle(.white.opacity(0.55))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 12)], spacing: 12) {
                    ForEach(friends) { friend in
                        OverlayFriendRow(friend: friend)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.07)))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08)))
                    }
                }
            }
        }
    }
}

struct OverlayFriendRow: View {
    @Environment(AppModel.self) private var model
    let friend: SteamFriend
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            Avatar(friend: friend, size: compact ? 30 : 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(friend.name).font(.callout.weight(.semibold)).lineLimit(1)
                Text(friend.state == .inGame ? (friend.game ?? "In a game") : (friend.state == .away ? "Away" : "Online"))
                    .font(.caption)
                    .foregroundStyle(friend.state == .inGame ? .green : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if friend.joinLink != nil, friend.appID != model.ownApp || model.ownLobby == nil {
                Button("Join") { model.join(friend) }
                    .buttonStyle(PillButtonStyle())
            }
            if model.ownApp != nil {
                if model.invitedFriends.contains(friend.id) {
                    Image(systemName: "checkmark").foregroundStyle(.green).help("Invited")
                } else {
                    Button("Invite") { model.invite(friend) }
                        .buttonStyle(GlassButtonStyle())
                }
            }
            if !compact {
                Button { model.chat(with: friend) } label: { Image(systemName: "bubble.left.fill") }
                    .buttonStyle(GlassButtonStyle())
                    .help("Chat in Steam")
                    .accessibilityLabel("Chat with \(friend.name) in Steam")
            }
        }
    }
}

// MARK: Clips

struct OverlayClipsTab: View {
    @Environment(AppModel.self) private var model
    @State private var onlyThisGame = true
    @State private var trimming: ClipItem?

    var body: some View {
        if let trimming {
            ClipTrimView(clip: trimming) { self.trimming = nil }
        } else {
            gallery
        }
    }

    private var gallery: some View {
        VStack(alignment: .leading, spacing: 14) {
            recorderCard
            HStack {
                Text("\(shown.count) SAVED").font(.caption.weight(.bold)).tracking(1.1).foregroundStyle(.white.opacity(0.55))
                Spacer()
                if model.runningGame != nil {
                    Picker("Show", selection: $onlyThisGame) {
                        Text("This game").tag(true)
                        Text("All games").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                }
                Button { model.showClipsFolder() } label: { Label("Show in Finder", systemImage: "folder") }
                    .buttonStyle(GlassButtonStyle())
            }
            if shown.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 42, weight: .light)).foregroundStyle(.white.opacity(0.35))
                    Text("Nothing saved yet").font(.headline)
                    Text("Clips and screenshots land here, and in Movies › Cellar Clips.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                        ForEach(shown) { clip in ClipCard(clip: clip) { trimming = clip } }
                    }
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var shown: [ClipItem] {
        guard onlyThisGame, let game = model.runningGame else { return model.clips }
        let name = ClipLibrary.items(game: game.name).first?.game
        return model.clips.filter { $0.game == name }
    }

    private var recorderCard: some View {
        OverlayCard {
            HStack(spacing: 16) {
                Toggle("", isOn: Binding(get: { model.clipsRecording || model.clipsStarting }, set: { model.setClipsRecording($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(.red)
                    .disabled(model.clipsStarting)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.clipsRecording ? "Clips are on" : "Clips are off").font(.headline)
                    Text(recorderDetail).font(.caption).foregroundStyle(.white.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { model.takeScreenshot() } label: { Label("Screenshot", systemImage: "camera.fill") }
                    .buttonStyle(GlassButtonStyle())
                Button { model.saveClip() } label: {
                    Label(model.savingClip ? "Saving…" : "Save clip", systemImage: "record.circle.fill")
                }
                .buttonStyle(PillButtonStyle())
                .disabled(!model.clipsRecording || model.savingClip)
            }
            if model.clipsNeedPermission {
                HStack(spacing: 12) {
                    Image(systemName: "lock.fill").foregroundStyle(.orange)
                    Text(model.clipsAskedThisLaunch ? "Allowed it in the macOS pop-up? Reopen Cellar to finish. No pop-up? Turn on Cellar in System Settings." : "Cellar needs Screen Recording permission for Clips and screenshots.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if model.clipsAskedThisLaunch {
                        Button("Settings") { model.openScreenRecordingSettings() }
                            .buttonStyle(GlassButtonStyle())
                        Button("Reopen Cellar") { model.relaunch() }
                            .buttonStyle(PillButtonStyle())
                    } else {
                        Button("Allow") { model.askForScreenRecording() }
                            .buttonStyle(PillButtonStyle())
                    }
                }
            }
            if let error = model.clipError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            }
        }
    }

    private var recorderDetail: String {
        if model.clipsRecording {
            return "Holding the last \(model.clipLengthLabel) in memory. \(OverlayController.clipHotkeyLabel) saves it, even without opening this. Other apps you switch to aren't recorded."
        }
        return "Off for this game. Turn on to keep the last \(model.clipLengthLabel) ready to save. It adds a little heat and battery use."
    }
}

struct ClipCard: View {
    @Environment(AppModel.self) private var model
    let clip: ClipItem
    let trim: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ClipThumbnail(clip: clip)
                .overlay {
                    if hovering {
                        ZStack {
                            Color.black.opacity(0.4)
                            Image(systemName: clip.kind == .video ? "play.circle.fill" : "eye.circle.fill")
                                .font(.system(size: 38))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { model.open(clip) }
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(clip.game).font(.callout.weight(.semibold)).lineLimit(1)
                    Text("\(clip.date.formatted(date: .abbreviated, time: .shortened))  ·  \(clip.size.formattedBytes)")
                        .font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 2)
                if clip.kind == .video { icon("scissors", "Trim", run: trim) }
                icon("doc.on.doc", "Copy, to paste into Discord") { model.copy(clip) }
                icon("folder", "Show in Finder") { model.reveal(clip) }
                icon("trash", "Move to Trash") { model.delete(clip) }
            }
        }
        .onHover { over in withAnimation(.snappy(duration: 0.14)) { hovering = over } }
    }

    private func icon(_ name: String, _ help: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: name)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct ClipThumbnail: View {
    let clip: ClipItem
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.white.opacity(0.06)
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: clip.kind == .video ? "video.fill" : "photo.fill").foregroundStyle(.white.opacity(0.3))
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: clip.id) { image = await Self.thumbnail(for: clip) }
    }

    private static func thumbnail(for clip: ClipItem) async -> CGImage? {
        if clip.kind == .video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 360)
            return try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        }
        let url = clip.url
        return await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 640]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }
}

// MARK: Performance

struct OverlayPerformanceTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sample = model.stats.last
        ScrollView {
            VStack(spacing: 14) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 200), spacing: 12), count: 3), spacing: 12) {
                    StatTile(title: "Frame rate", value: frameRateText, detail: model.clipsRecording ? "Measured from Clips, up to 60" : "Turn on Clips to measure it",
                             history: model.clipsRecording ? model.frameRates : nil, maximum: 60)
                        .frame(height: 150)
                    StatTile(title: "Game CPU", value: sample.map { "\(Int($0.gameCPU * 100))%" } ?? "–", detail: "Share of this Mac's whole CPU",
                             history: model.stats.map(\.gameCPU), maximum: max(model.stats.map(\.gameCPU).max() ?? 1, 0.2))
                        .frame(height: 150)
                    StatTile(title: "Game memory", value: gameMemoryText(sample), detail: memoryDetail(sample),
                             history: model.stats.map(\.memoryUsed))
                        .frame(height: 150)
                    StatTile(title: "Heat", value: sample?.thermal.title ?? "–", detail: heatDetail(sample?.thermal), color: heatColor(sample?.thermal))
                        .frame(height: 150)
                    StatTile(title: "Battery", value: sample?.battery.map { "\(Int(($0 * 100).rounded()))%" } ?? "No battery", detail: batteryDetail(sample),
                             history: model.stats.compactMap(\.battery))
                        .frame(height: 150)
                    VolumeTile()
                        .frame(height: 150)
                }
                if let advice {
                    OverlayCard {
                        Label(advice, systemImage: "lightbulb.fill")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let game = model.runningGame {
                    OverlayCard { RecommendedSettingsView(game: game) }
                    presets(game)
                }
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
    }

    private var frameRateText: String {
        guard model.clipsRecording, let rate = model.frameRates.last else { return "–" }
        return rate >= 59 ? "60+" : "\(Int(rate.rounded()))"
    }

    private func memoryDetail(_ sample: SystemSample?) -> String {
        guard let sample else { return "" }
        return "This Mac is using \(Int(sample.memoryUsed * 100))% of its \(model.host.memoryGB) GB"
    }

    private func heatDetail(_ level: ThermalLevel?) -> String {
        switch level {
        case .warm: "Warming up. Fine for now."
        case .hot: "macOS is slowing things down to cool off."
        case .critical: "macOS is slowing things down a lot."
        default: "Running at full speed."
        }
    }

    private func heatColor(_ level: ThermalLevel?) -> Color {
        switch level {
        case .warm: .orange
        case .hot, .critical: .red
        default: .green
        }
    }

    private func batteryDetail(_ sample: SystemSample?) -> String {
        guard let sample, sample.battery != nil else { return "" }
        if !sample.onBattery { return sample.charging ? "Charging" : "Plugged in" }
        if let minutes = sample.batteryMinutesLeft { return "About \(AppModel.playTime(Double(minutes) * 60)) left" }
        if let start = model.sessionBatteryStart, let now = sample.battery, start > now {
            return "\(Int(((start - now) * 100).rounded()))% used this session"
        }
        return "On battery"
    }

    /// Only speaks up when there's something worth doing.
    private var advice: String? {
        guard let sample = model.stats.last else { return nil }
        let canCap = model.runningGame?.profile.backend.supportsFrameCap == true
        if sample.thermal >= .hot {
            return canCap ? "Your Mac is hot, so frames will drop. The Battery preset below limits this game to 30 fps from its next launch, which should keep things steadier."
                : "Your Mac is hot, so frames will drop. Lower the graphics or limit the frame rate in the game's own settings to keep things steadier."
        }
        if Double(model.host.memoryGB) * sample.memoryUsed > Double(model.host.memoryGB) - 1 {
            return "Memory is nearly full, which causes stutter. Closing other apps will help."
        }
        if sample.onBattery, let battery = sample.battery, battery < 0.2 {
            return "Battery is under 20%. Plug in soon, or save your game."
        }
        return nil
    }

    private func presets(_ game: Game) -> some View {
        OverlayCard(title: "Preset, from the next launch") {
            let current = model.core.profiles.profile(for: game.id)
            HStack(spacing: 10) {
                ForEach(GamePreset.allCases) { preset in
                    PresetCard(preset: preset, selected: (current.preset ?? .quality) == preset, backend: current.backend) {
                        model.updateSettings(for: game) { $0.preset = preset; $0.frameCap = nil }
                    }
                }
            }
        }
    }
}

// MARK: Game

struct OverlayGameTab: View {
    @Environment(AppModel.self) private var model
    @State private var notes = ""
    @State private var loadedFor: String?
    @State private var confirmingQuit = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            OverlayCard(title: "Notes") {
                TextEditor(text: $notes)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .topLeading) {
                        if notes.isEmpty {
                            Text("Controls, codes, where you got up to. Saved for this game.")
                                .foregroundStyle(.white.opacity(0.4))
                                .padding(.leading, 6)
                                .allowsHitTesting(false)
                        }
                    }
            }
            .frame(maxHeight: .infinity)

            VStack(spacing: 16) {
                if let game = model.runningGame, let assessment = model.verdicts[game.id] {
                    OverlayCard { VerdictDetails(gameID: game.id, assessment: assessment) }
                }
                if let game = model.runningGame { links(game) }
                quit
            }
            .frame(width: 400)
        }
        .onAppear(perform: load)
        .onChange(of: model.runningGame?.id) { load() }
        .onChange(of: notes) {
            if let id = loadedFor { model.saveNotes(notes, for: id) }
        }
    }

    private func load() {
        guard let id = model.runningGame?.id, id != loadedFor else { return }
        loadedFor = nil
        notes = model.notes(for: id)
        loadedFor = id
    }

    private func links(_ game: Game) -> some View {
        OverlayCard(title: "Help and links") {
            HStack(spacing: 8) {
                link("Guides", "book.fill", "https://steamcommunity.com/app/\(game.id)/guides")
                link("Community", "person.3.fill", "https://steamcommunity.com/app/\(game.id)")
                link("Store", "storefront.fill", "https://store.steampowered.com/app/\(game.id)")
            }
            Button {
                model.overlay.hide()
                model.showInFinder(game)
            } label: {
                Label("Show game files", systemImage: "folder")
            }
            .buttonStyle(GlassButtonStyle())
        }
    }

    private func link(_ title: String, _ icon: String, _ address: String) -> some View {
        Button {
            model.overlay.hide()
            if let url = URL(string: address) { NSWorkspace.shared.open(url) }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 15))
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var quit: some View {
        OverlayCard(title: "Leave") {
            if confirmingQuit {
                Text("This force-quits the game, so anything unsaved is lost.").font(.callout)
                HStack {
                    Button("Quit Game") { model.quitGame() }
                        .buttonStyle(PillButtonStyle())
                    Button("Cancel") { confirmingQuit = false }
                        .buttonStyle(GlassButtonStyle())
                }
            } else {
                HStack {
                    Button { confirmingQuit = true } label: { Label("Quit Game", systemImage: "stop.fill") }
                        .buttonStyle(GlassButtonStyle())
                    Text("Steam stays open, so the next game starts quickly.")
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }
}
