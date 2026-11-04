import AVFoundation
import CellarKit
import SwiftUI

/// The console-style shell. Two places to be, Games and Friends, plus Settings, and a game's own
/// screen laid over the top.
struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .top) {
            Theme.ground.ignoresSafeArea()
            Group {
                switch model.tab {
                case .games:
                    if model.showAllGames { AllGamesView().padding(.top, 58) } else { GamesView() }
                case .clips: ClipsScreen().padding(.top, 58)
                case .friends: FriendsView().padding(.top, 58)
                case .settings: SettingsScreen().padding(.top, 58)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            TopBar()
            if let game = model.settingsGame {
                GameScreen(game: game)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let clip = model.viewingClip {
                ClipEditorView(clip: clip) { model.viewingClip = nil }
                    .padding(.horizontal, 28)
                    .padding(.top, 34)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.ground)
                    .id(clip.id)
                    .transition(.opacity)
            }
            if let toast = model.toast {
                Toast(text: toast) { model.toast = nil }
                    .padding(.top, 62)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.28), value: model.tab)
        .animation(.smooth(duration: 0.28), value: model.showAllGames)
        .animation(.smooth(duration: 0.26), value: model.settingsGame?.id)
        .animation(.smooth(duration: 0.22), value: model.viewingClip == nil)
        .animation(.smooth, value: model.toast)
        .task { model.startFriends() }
    }
}

struct TopBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 22) {
            Wordmark()
            if model.tab == .settings {
                Button { model.closeSettings() } label: {
                    Label("Back to \(model.settingsReturnTab.rawValue)", systemImage: "chevron.left")
                }
                .buttonStyle(PillButtonStyle())
                .keyboardShortcut(.cancelAction)
                .help("Leave Settings (Esc)")
            } else {
                ForEach(Tab.navigation) { tab in
                    Button {
                        model.tab = tab
                        model.showAllGames = false
                    } label: {
                        Text(tab.rawValue)
                            .font(.cellar(14, model.tab == tab ? .bold : .medium))
                            .foregroundStyle(model.tab == tab ? .white : .white.opacity(0.72))
                            .padding(.vertical, 8)
                            .overlay(alignment: .bottom) {
                                if model.tab == tab { Capsule().fill(.white).frame(height: 2) }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(Character(String((Tab.navigation.firstIndex(of: tab) ?? 0) + 1))), modifiers: .command)
                }
            }
            // The title bar is hidden, so the empty part of the top bar moves the window.
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
            if model.runningGame != nil || model.launching != nil {
                Button { model.stopAll() } label: { Label("Force Quit", systemImage: "stop.fill") }
                    .buttonStyle(GlassButtonStyle())
                    .help("Force-quit Steam and every game (⇧⌘K)")
            }
            SteamButton()
            if model.tab != .settings {
                Button("Settings") { model.openSettings() }
                    .buttonStyle(GlassButtonStyle())
            }
        }
        .padding(.leading, 84)   // clear of the window buttons
        .padding(.trailing, 22)
        .padding(.top, 8)
        .frame(height: 52)
    }
}

// MARK: Games

struct GamesView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        if let game = model.focusedGame {
            ZStack(alignment: .bottomLeading) {
                GameBackdrop(game: game)
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 60)
                    HStack(alignment: .bottom) {
                        GameHeading(game: game)
                        Spacer(minLength: 24)
                        if !model.friendsInGame.isEmpty || !model.friendsOnline.isEmpty {
                            FriendsPeek().padding(.bottom, 4)
                        }
                    }
                    .padding(.horizontal, 44)
                    Shelf(games: model.installedGames)
                        .padding(.top, 20)
                    if !model.downloadingGames.isEmpty {
                        DownloadStrip().padding(.bottom, 12)
                    }
                }
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { move(-1) }
            .onKeyPress(.rightArrow) { move(1) }
            .onKeyPress(.return) { model.play(game); return .handled }
            .onAppear { focused = true }
        } else {
            EmptyHome()
        }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        let games = model.installedGames
        guard let current = games.firstIndex(where: { $0.id == model.focusedGame?.id }) else { return .ignored }
        model.focusedGameID = games[min(max(current + delta, 0), games.count - 1)].id
        return .handled
    }
}

/// The selected game's art filling the window, with its trailer fading in over the art when it can.
struct GameBackdrop: View {
    @Environment(AppModel.self) private var model
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let game: Game
    @State private var player: AVPlayer?
    @State private var playing = false

    /// Video never competes with a running game, and stops when Cellar isn't in front.
    private var shouldPlay: Bool {
        model.trailersEnabled && !reduceMotion && model.runningGame == nil && model.launching == nil
            && model.settingsGame == nil && activeState != .inactive && !model.steamOffline
    }

    var body: some View {
        ZStack {
            Theme.ground
            Color.clear
                .overlay { ArtworkImage(url: game.artwork?.hero ?? game.artwork?.header) }
                .clipped()
                .id(game.id)
                .transition(.opacity)
            if let player {
                ClipVideoView(player: player, fills: true)
                    .opacity(playing ? 1 : 0)
                    .animation(.easeIn(duration: 0.7), value: playing)
                    .allowsHitTesting(false)
            }
            LinearGradient(stops: [.init(color: .black.opacity(0.62), location: 0), .init(color: .clear, location: 0.2),
                                   .init(color: .black.opacity(0.22), location: 0.42), .init(color: Theme.ground.opacity(0.98), location: 0.84)],
                           startPoint: .top, endPoint: .bottom)
        }
        .animation(.smooth(duration: 0.45), value: game.id)
        .ignoresSafeArea()
        .task(id: trailerKey) { await runTrailer() }
    }

    private var trailerKey: String { "\(game.id)-\(shouldPlay)" }

    private func runTrailer() async {
        player?.pause()
        player = nil
        playing = false
        guard shouldPlay else { return }
        // Moving along the shelf quickly shouldn't start a download for every game passed.
        try? await Task.sleep(for: .seconds(1.2))
        guard !Task.isCancelled, let url = await model.trailers.trailer(appID: game.id) else { return }
        guard !Task.isCancelled else { return }
        let item = AVPlayerItem(url: url)
        item.preferredPeakBitRate = 5_000_000
        let video = AVPlayer(playerItem: item)
        video.isMuted = true
        video.actionAtItemEnd = .none
        player = video
        video.play()
        while !Task.isCancelled {
            if video.timeControlStatus == .playing, video.currentTime().seconds > 0.1 { playing = true }
            if let duration = video.currentItem?.duration.seconds, duration.isFinite, video.currentTime().seconds >= duration - 0.3 {
                await video.seek(to: .zero)
                video.play()
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        video.pause()
    }
}

struct GameHeading: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ArtworkLogo(url: game.artwork?.logo, name: game.name)
                .id(game.id)
            HStack(spacing: 12) {
                if let assessment = model.verdicts[game.id] {
                    VerdictButton(game: game, assessment: assessment)
                }
                if let last = game.lastPlayed {
                    Text("Played " + last.formatted(.relative(presentation: .named)))
                        .font(.cCallout)
                        .foregroundStyle(.white.opacity(0.84))
                }
            }
            HStack(spacing: 12) {
                PlayControl(game: game)
                Button("Game settings") { model.settingsGame = game }
                    .buttonStyle(GlassButtonStyle(large: true))
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}

struct ArtworkLogo: View {
    let url: URL?
    let name: String

    var body: some View {
        AsyncImage(url: url) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFit()
                    .frame(maxWidth: 280, maxHeight: 84, alignment: .leading)
                    .shadow(color: .black.opacity(0.55), radius: 10)
            } else {
                Text(name)
                    .font(.cellar(34, .heavy))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.55), radius: 10)
            }
        }
    }
}

struct PlayControl: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        if game.isRunning {
            Button { model.stopAll() } label: { Label("Stop", systemImage: "stop.fill").frame(minWidth: 90) }
                .buttonStyle(GlassButtonStyle(large: true))
        } else if model.launching == game.id {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Starting…").font(.cellar(16, .bold))
            }
            .padding(.horizontal, 28)
            .frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.14)))
        } else {
            Button("Play") { model.play(game) }
                .buttonStyle(PillButtonStyle(large: true))
        }
    }
}

/// The row of covers along the bottom. The selected one is larger and outlined.
struct Shelf: View {
    @Environment(AppModel.self) private var model
    let games: [Game]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 14) {
                    ForEach(games) { game in
                        ShelfCard(game: game, focused: game.id == model.focusedGame?.id, verdict: model.verdicts[game.id]?.verdict)
                            .id(game.id)
                            .onTapGesture(count: 2) { model.play(game) }
                            .onTapGesture { model.focusedGameID = game.id }
                    }
                    Button { model.showAllGames = true } label: {
                        Text("All games")
                            .font(.cellar(13, .bold))
                            .frame(width: 104, height: 156)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.08)))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.24)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 44)
                .padding(.vertical, 22)
            }
            .onChange(of: model.focusedGame?.id) { _, id in
                withAnimation(.smooth) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

struct ShelfCard: View {
    let game: Game
    let focused: Bool
    var verdict: CompatibilityVerdict?
    @State private var hovering = false

    private var size: CGSize { focused ? CGSize(width: 126, height: 186) : CGSize(width: 104, height: 156) }

    var body: some View {
        ArtworkImage(url: game.artwork?.capsule, fallbackTitle: game.name)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(focused ? 1 : (hovering ? 0.5 : 0.16)), lineWidth: focused ? 3 : 1)
            }
            .overlay(alignment: .topTrailing) {
                if game.isRunning {
                    Circle().fill(Theme.positive).frame(width: 10, height: 10).padding(8)
                }
            }
            .shadow(color: .black.opacity(focused ? 0.55 : 0.3), radius: focused ? 16 : 6, y: focused ? 8 : 3)
            .scaleEffect(hovering && !focused ? 1.03 : 1)
            .animation(.snappy(duration: 0.2), value: focused)
            .animation(.snappy(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
            .help(game.name)
            .contentShape(Rectangle())
    }
}

struct DownloadStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
            ForEach(model.downloadingGames.prefix(3)) { game in
                HStack(spacing: 6) {
                    Text(game.name).lineLimit(1)
                    if let p = game.app.downloadProgress {
                        ProgressView(value: p).frame(width: 70).tint(.white)
                        Text("\(Int(p * 100))%").monospacedDigit().foregroundStyle(Theme.secondaryText)
                    } else {
                        Text(game.app.isUpdating ? "updating" : "queued").foregroundStyle(Theme.secondaryText)
                    }
                }
            }
        }
        .font(.cCallout)
        .padding(.horizontal, 44)
    }
}

/// Who's on, small and out of the way. The whole list is one click away.
struct FriendsPeek: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let friends = Array((model.friendsInGame + model.friendsOnline).prefix(4))
        VStack(alignment: .trailing, spacing: 9) {
            Text("\(model.friendsInGame.count + model.friendsOnline.count) friends online")
                .font(.cellar(11.5, .bold))
                .foregroundStyle(.white.opacity(0.84))
            ForEach(friends) { friend in
                Button { model.tab = .friends } label: {
                    HStack(spacing: 9) {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(friend.name).font(.cellar(12.5, .semibold)).lineLimit(1)
                            Text(friend.game ?? "Online")
                                .font(.cCaption)
                                .foregroundStyle(friend.state == .inGame ? Theme.positive : .white.opacity(0.72))
                                .lineLimit(1)
                        }
                        Avatar(friend: friend, size: 30)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 240, alignment: .trailing)
    }
}

struct EmptyHome: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            AppMark(size: 72)
            Text("Let's get a game").font(.cellar(30, .heavy))
            Text(model.steamUser == nil
                 ? "Open Steam and sign in. Games you install there show up here."
                 : "Install something in Steam. It shows up here when it's ready.")
                .font(.cBody)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Open Steam") { model.openSteam() }
                .buttonStyle(PillButtonStyle(large: true))
                .padding(.top, 4)
            if !model.downloadingGames.isEmpty { DownloadStrip().padding(.top, 10) }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: All games

struct AllGamesView: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 20)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("All games").font(.cellar(32, .heavy))
                    Text(model.installedGames.count == 1 ? "1 game" : "\(model.installedGames.count) games")
                        .font(.cCallout).foregroundStyle(Theme.secondaryText)
                    Spacer()
                    Button("Back") { model.showAllGames = false }
                        .buttonStyle(GlassButtonStyle())
                }
                WillItRunSearch()
                LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                    ForEach(model.installedGames) { LibraryCard(game: $0) }
                }
                if !model.downloadingGames.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Downloading").font(.cHeadline)
                        ForEach(model.downloadingGames) { game in
                            HStack(spacing: 14) {
                                ArtworkImage(url: game.artwork?.header).frame(width: 120, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(game.name).font(.cHeadline)
                                    if let p = game.app.downloadProgress {
                                        ProgressView(value: p).tint(.white)
                                        Text("\(game.app.bytesDownloaded.formattedBytes) of \(game.app.bytesToDownload.formattedBytes)")
                                            .font(.cCaption).foregroundStyle(Theme.secondaryText).monospacedDigit()
                                    } else {
                                        Text(game.app.isUpdating ? "Updating…" : "Waiting in Steam's queue").font(.cCaption).foregroundStyle(Theme.secondaryText)
                                    }
                                }
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
                        }
                    }
                }
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 18)
        }
    }
}

struct LibraryCard: View {
    @Environment(AppModel.self) private var model
    let game: Game
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ArtworkImage(url: game.artwork?.capsule, fallbackTitle: game.name)
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .bottom) {
                    if hovering && !game.isRunning {
                        Button("Play") { model.play(game) }
                            .buttonStyle(PillButtonStyle())
                            .padding(12)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(hovering ? 0.4 : 0.1))
                }
                .scaleEffect(hovering ? 1.02 : 1)
            Text(game.name).font(.cHeadline).lineLimit(1)
            Text(game.isRunning ? "Running" : (model.verdicts[game.id]?.verdict.title ?? " "))
                .font(.cCaption)
                .foregroundStyle(game.isRunning ? Theme.positive : Theme.secondaryText)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.focusedGameID = game.id
            model.showAllGames = false
        }
        .onHover { h in withAnimation(.snappy(duration: 0.18)) { hovering = h } }
        .contextMenu {
            Button("Play") { model.play(game) }
            Button("Game Settings…") { model.settingsGame = game }
            Button("Add to Dock") { model.addToDock(game) }
            Button("Show in Finder") { model.showInFinder(game) }
            Button("Store Page") { model.openStorePage(game) }
        }
    }
}

// MARK: Friends

struct FriendsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Friends").font(.cellar(32, .heavy))
                if !model.friendsLoaded {
                    HStack { ProgressView().controlSize(.small); Text("Checking who's on…").font(.cBody).foregroundStyle(Theme.secondaryText) }
                } else if model.friends.isEmpty {
                    Text(model.steamUser == nil ? "Sign in to Steam to see your friends." : "No friends found in this Steam account yet.")
                        .font(.cBody).foregroundStyle(Theme.secondaryText)
                }
                section("Playing now", model.friendsInGame)
                section("Online", model.friendsOnline)
                section("Offline or private", model.friends.filter { $0.state == .offline || $0.state == .unknown })
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 44).padding(.vertical, 18)
        }
    }

    @ViewBuilder private func section(_ title: String, _ friends: [SteamFriend]) -> some View {
        if !friends.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(title), \(friends.count)")
                    .font(.cellar(12, .bold)).foregroundStyle(Theme.secondaryText)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
                    ForEach(friends) { FriendRow(friend: $0) }
                }
            }
        }
    }
}

struct FriendRow: View {
    @Environment(AppModel.self) private var model
    let friend: SteamFriend

    var body: some View {
        HStack(spacing: 12) {
            Avatar(friend: friend, size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(friend.name).font(.cHeadline).lineLimit(1)
                Text(status).font(.cCaption).lineLimit(1)
                    .foregroundStyle(friend.state == .inGame ? Theme.positive : Theme.secondaryText)
            }
            Spacer()
            if friend.joinLink != nil {
                Button("Join") { model.join(friend) }
                    .buttonStyle(PillButtonStyle())
                    .help("Join \(friend.name) in \(friend.game ?? "their game")")
            }
            Button { model.chat(with: friend) } label: { Image(systemName: "bubble.left.fill") }
                .buttonStyle(GlassButtonStyle())
                .help("Chat in Steam")
                .accessibilityLabel("Chat with \(friend.name) in Steam")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
    }

    private var status: String {
        switch friend.state {
        case .inGame: "Playing \(friend.game ?? "a game")"
        case .online: "Online"
        case .away: friend.statusText ?? "Away"
        case .offline: "Offline"
        case .unknown: "Private profile"
        }
    }
}

struct Avatar: View {
    let friend: SteamFriend
    let size: CGFloat

    var body: some View {
        AsyncImage(url: friend.avatar) { phase in
            if case .success(let image) = phase { image.resizable().scaledToFill() } else { Color.white.opacity(0.14) }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(friend.state == .inGame ? Theme.positive : (friend.state == .online ? Color.white : Color.gray))
                .frame(width: size * 0.28, height: size * 0.28)
                .overlay(Circle().stroke(.black.opacity(0.7), lineWidth: 2))
                .opacity(friend.state == .offline || friend.state == .unknown ? 0 : 1)
        }
    }
}

struct Toast: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.positive)
            Text(text).font(.cCallout)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Theme.secondaryText)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(white: 0.11)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
        .task {
            try? await Task.sleep(for: .seconds(6))
            dismiss()
        }
    }
}
