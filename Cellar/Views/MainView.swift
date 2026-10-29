import CellarKit
import SwiftUI

/// The console-style shell: the focused game's art fills the window, a top bar holds the tabs.
struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .top) {
            Backdrop(game: model.tab == .home ? model.focusedGame : nil)
            VStack(spacing: 0) {
                TopBar()
                Group {
                    switch model.tab {
                    case .home: HomeView()
                    case .library: LibraryView()
                    case .friends: FriendsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let toast = model.toast {
                Toast(text: toast) { model.toast = nil }
                    .padding(.top, 70)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.35), value: model.tab)
        .animation(.smooth, value: model.toast)
        .sheet(item: $model.settingsGame) { game in
            GameSettingsSheet(game: game)
                .environment(model)
        }
        .task { model.startFriends() }
    }
}

/// Full-bleed hero art behind everything, cross-fading when the focused game changes.
struct Backdrop: View {
    let game: Game?

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.04, blue: 0.05)
            if let game {
                Color.clear
                    .overlay { ArtworkImage(url: game.artwork?.hero ?? game.artwork?.header) }
                    .clipped()
                    .id(game.id)
                    .transition(.opacity)
            } else {
                LinearGradient(colors: [Color(red: 0.22, green: 0.04, blue: 0.09), Color(red: 0.05, green: 0.03, blue: 0.05)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            // Darken toward the bottom and left, where text and the shelf sit.
            LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .clear, location: 0.18),
                                   .init(color: .clear, location: 0.38), .init(color: .black.opacity(0.92), location: 0.8)],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .leading, endPoint: .center)
        }
        .animation(.smooth(duration: 0.5), value: game?.id)
        .ignoresSafeArea()
    }
}

struct TopBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 16) {
            AppMark(size: 26)
            HStack(spacing: 4) {
                ForEach(Tab.allCases) { tab in
                    Button { model.tab = tab } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(Capsule().fill(model.tab == tab ? .white.opacity(0.18) : .clear))
                            .foregroundStyle(model.tab == tab ? .white : .white.opacity(0.65))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(Character(String(Tab.allCases.firstIndex(of: tab)! + 1))), modifiers: .command)
                }
            }
            .padding(3)
            .background(Capsule().fill(.black.opacity(0.25)))
            Spacer()
            if model.runningGame != nil || model.launching != nil {
                Button { model.stopAll() } label: { Label("Force Quit", systemImage: "stop.fill") }
                    .buttonStyle(GlassButtonStyle())
                    .help("Force-quit Steam and every game (⇧⌘K)")
            }
            Button { model.openSteam() } label: {
                HStack(spacing: 7) {
                    StatusDot(on: model.steamRunning)
                    Text(model.steamUser ?? "Steam")
                }
            }
            .buttonStyle(GlassButtonStyle())
            .help(model.steamRunning ? "Steam is running. Click to show it." : "Open Steam")
            SettingsLink { Image(systemName: "gearshape.fill") }
                .buttonStyle(GlassButtonStyle())
                .help("Settings")
                .accessibilityLabel("Settings")
        }
        .padding(.leading, 84)   // clear of the window buttons
        .padding(.trailing, 20)
        .padding(.top, 10)
        .frame(height: 52)
    }
}

// MARK: Home

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var shelfFocused: Bool

    var body: some View {
        if let game = model.focusedGame {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 20)
                HStack(alignment: .bottom) {
                    HeroInfo(game: game)
                    Spacer()
                    if !model.friendsInGame.isEmpty || !model.friendsOnline.isEmpty {
                        FriendsPeek().padding(.bottom, 6)
                    }
                }
                .padding(.horizontal, 44)
                Shelf(title: "Your games", games: model.installedGames)
                    .padding(.top, 30)
                if !model.downloadingGames.isEmpty {
                    DownloadStrip().padding(.top, 6)
                }
                Spacer(minLength: 24).frame(maxHeight: 28)
            }
            .focusable()
            .focused($shelfFocused)
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { move(-1) }
            .onKeyPress(.rightArrow) { move(1) }
            .onKeyPress(.return) { model.play(game); return .handled }
            .onAppear { shelfFocused = true }
        } else {
            EmptyHome()
        }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        let games = model.installedGames
        guard let current = games.firstIndex(where: { $0.id == model.focusedGame?.id }) else { return .ignored }
        let next = min(max(current + delta, 0), games.count - 1)
        model.focusedGameID = games[next].id
        return .handled
    }
}

struct HeroInfo: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AsyncImage(url: game.artwork?.logo) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFit().frame(maxWidth: 380, maxHeight: 130, alignment: .leading)
                        .shadow(color: .black.opacity(0.6), radius: 10)
                } else {
                    Text(game.name)
                        .font(.system(size: 46, weight: .heavy))
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .shadow(color: .black.opacity(0.6), radius: 10)
                }
            }
            .id(game.id)
            Text(meta)
                .font(.callout.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
            HStack(spacing: 12) {
                PlayControl(game: game)
                CircleIconButton(systemImage: "slider.horizontal.3", help: "Game settings") { model.settingsGame = game }
                CircleIconButton(systemImage: "dock.rectangle", help: "Add to Dock") { model.addToDock(game) }
                CircleIconButton(systemImage: "folder", help: "Show game files in Finder") { model.showInFinder(game) }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .transition(.opacity)
        .animation(.smooth, value: game.id)
    }

    private var meta: String {
        var parts = [game.profile.backend.shortName, game.app.sizeOnDisk.formattedBytes]
        if game.profile.metalHUD ?? model.showFPS { parts.append("FPS counter on") }
        if let last = game.lastPlayed {
            parts.append("Played " + last.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: "  ·  ")
    }
}

struct PlayControl: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        if game.isRunning {
            Button { model.stopAll() } label: { Label("Stop", systemImage: "stop.fill").frame(minWidth: 110) }
                .buttonStyle(PillButtonStyle(large: true, tint: .white.opacity(0.22)))
        } else if model.launching == game.id {
            HStack(spacing: 10) { ProgressView().controlSize(.small).tint(.white); Text("Starting…") }
                .font(.title3.weight(.semibold))
                .frame(minWidth: 110)
                .padding(.horizontal, 28).padding(.vertical, 11)
                .background(Capsule().fill(.white.opacity(0.14)))
        } else {
            Button { model.play(game) } label: { Label("Play", systemImage: "play.fill").frame(minWidth: 110) }
                .buttonStyle(PillButtonStyle(large: true))
        }
    }
}

/// The row of covers at the bottom of Home; the focused one is raised and outlined.
struct Shelf: View {
    @Environment(AppModel.self) private var model
    let title: String
    let games: [Game]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 44)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(games) { game in
                            ShelfCard(game: game, focused: game.id == model.focusedGame?.id)
                                .id(game.id)
                                .onTapGesture(count: 2) { model.play(game) }
                                .onTapGesture { model.focusedGameID = game.id }
                        }
                    }
                    .padding(.horizontal, 44)
                    .padding(.vertical, 12)
                }
                .onChange(of: model.focusedGame?.id) { _, id in
                    withAnimation(.smooth) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }
}

struct ShelfCard: View {
    let game: Game
    let focused: Bool
    @State private var hovering = false

    var body: some View {
        ArtworkImage(url: game.artwork?.capsule, fallbackTitle: game.name)
            .frame(width: 128, height: 192)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(focused ? 0.95 : (hovering ? 0.4 : 0.1)), lineWidth: focused ? 3 : 1)
            }
            .overlay(alignment: .topTrailing) {
                if game.isRunning {
                    Circle().fill(.green).frame(width: 10, height: 10).padding(8)
                }
            }
            .shadow(color: .black.opacity(focused ? 0.6 : 0.35), radius: focused ? 18 : 8, y: focused ? 10 : 4)
            .scaleEffect(focused ? 1.08 : (hovering ? 1.03 : 1))
            .animation(.snappy(duration: 0.2), value: focused)
            .animation(.snappy(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
            .help(game.name)
    }
}

struct DownloadStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
            ForEach(model.downloadingGames.prefix(3)) { game in
                HStack(spacing: 6) {
                    Text(game.name).lineLimit(1)
                    if let p = game.app.downloadProgress {
                        ProgressView(value: p).frame(width: 70).tint(.accentColor)
                        Text("\(Int(p * 100))%").monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        Text(game.app.isUpdating ? "updating" : "queued").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 44)
    }
}

/// Friends who are in a game or online, shown small on the right of Home.
struct FriendsPeek: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Text("FRIENDS")
                .font(.caption.weight(.bold)).tracking(1.2)
                .foregroundStyle(.white.opacity(0.6))
            ForEach((model.friendsInGame + model.friendsOnline).prefix(4)) { friend in
                HStack(spacing: 8) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(friend.name).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(friend.game ?? "Online")
                            .font(.caption)
                            .foregroundStyle(friend.state == .inGame ? .green : .white.opacity(0.6))
                            .lineLimit(1)
                    }
                    Avatar(friend: friend, size: 30)
                }
                .onTapGesture { model.tab = .friends }
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
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 54))
                .foregroundStyle(.white.opacity(0.8))
            Text("Let's get a game").font(.system(size: 32, weight: .heavy))
            Text(model.steamUser == nil
                 ? "Open Steam and sign in. Games you install there show up here."
                 : "Install something in Steam. It shows up here when it's ready.")
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Open Steam") { model.openSteam() }
                .buttonStyle(PillButtonStyle(large: true))
                .padding(.top, 4)
            if !model.downloadingGames.isEmpty { DownloadStrip().padding(.top, 10) }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: Library

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 22)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Library").font(.system(size: 30, weight: .heavy))
                Text(model.installedGames.count == 1 ? "1 game" : "\(model.installedGames.count) games")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 44).padding(.top, 18)

            if model.installedGames.isEmpty && model.downloadingGames.isEmpty {
                EmptyHome().frame(height: 400)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                ForEach(model.installedGames) { game in
                    LibraryCard(game: game)
                }
            }
            .padding(.horizontal, 44).padding(.vertical, 20)

            if !model.downloadingGames.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("DOWNLOADING").font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.secondary)
                    ForEach(model.downloadingGames) { game in
                        HStack(spacing: 14) {
                            ArtworkImage(url: game.artwork?.header).frame(width: 120, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(game.name).font(.headline)
                                if let p = game.app.downloadProgress {
                                    ProgressView(value: p).tint(.accentColor)
                                    Text("\(game.app.bytesDownloaded.formattedBytes) of \(game.app.bytesToDownload.formattedBytes)")
                                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                } else {
                                    Text(game.app.isUpdating ? "Updating…" : "Waiting in Steam's queue").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
                    }
                }
                .padding(.horizontal, 44).padding(.bottom, 30)
            }
        }
    }
}

struct LibraryCard: View {
    @Environment(AppModel.self) private var model
    let game: Game
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkImage(url: game.artwork?.capsule, fallbackTitle: game.name)
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottom) {
                    if hovering && !game.isRunning {
                        Button { model.play(game) } label: { Label("Play", systemImage: "play.fill") }
                            .buttonStyle(PillButtonStyle())
                            .padding(12)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(hovering ? 0.35 : 0.08))
                }
                .shadow(color: .black.opacity(hovering ? 0.45 : 0.25), radius: hovering ? 14 : 6, y: hovering ? 8 : 3)
                .scaleEffect(hovering ? 1.03 : 1)
            Text(game.name).font(.headline).lineLimit(1)
            Text(game.isRunning ? "Running" : game.profile.backend.shortName)
                .font(.caption).foregroundStyle(game.isRunning ? .green : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.focusedGameID = game.id
            model.tab = .home
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
            VStack(alignment: .leading, spacing: 4) {
                Text("Friends").font(.system(size: 30, weight: .heavy))
                Text("From your Steam account. Status comes from public profiles and refreshes every minute.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 44).padding(.top, 18)

            VStack(alignment: .leading, spacing: 22) {
                if !model.friendsLoaded {
                    HStack { ProgressView().controlSize(.small); Text("Checking who's on…").foregroundStyle(.secondary) }
                } else if model.friends.isEmpty {
                    Text(model.steamUser == nil ? "Sign in to Steam to see your friends." : "No friends found in this Steam account yet.")
                        .foregroundStyle(.secondary)
                }
                section("Playing now", model.friendsInGame)
                section("Online", model.friendsOnline)
                section("Offline or private", model.friends.filter { $0.state == .offline || $0.state == .unknown })
            }
            .padding(.horizontal, 44).padding(.vertical, 20)
        }
    }

    @ViewBuilder private func section(_ title: String, _ friends: [SteamFriend]) -> some View {
        if !friends.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(title.uppercased())  \(friends.count)")
                    .font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
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
            Avatar(friend: friend, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(friend.name).font(.headline).lineLimit(1)
                Text(status).font(.caption).lineLimit(1)
                    .foregroundStyle(friend.state == .inGame ? .green : .secondary)
            }
            Spacer()
            if friend.state == .inGame, let game = model.installedGame(named: friend.game) {
                Button("Play") { model.play(game) }
                    .buttonStyle(PillButtonStyle())
                    .help("You have \(game.name) too")
            }
            Button { model.chat(with: friend) } label: { Image(systemName: "bubble.left.fill") }
                .buttonStyle(GlassButtonStyle())
                .help("Chat in Steam")
                .accessibilityLabel("Chat with \(friend.name) in Steam")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.06)))
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
            if case .success(let image) = phase { image.resizable().scaledToFill() } else { Color.white.opacity(0.12) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(friend.state == .inGame ? Color.green : (friend.state == .online ? Color.blue : Color.gray))
                .frame(width: size * 0.3, height: size * 0.3)
                .overlay(Circle().stroke(.black.opacity(0.6), lineWidth: 2))
                .offset(x: 3, y: 3)
                .opacity(friend.state == .offline || friend.state == .unknown ? 0 : 1)
        }
    }
}

struct Toast: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(text).font(.callout)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .task {
            try? await Task.sleep(for: .seconds(6))
            dismiss()
        }
    }
}
