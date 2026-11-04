# Cellar

Run Windows Steam games on Apple Silicon Macs. Free, noncommercial, for friends.

Cellar is a front-end. Under it is Wine built from CodeWeavers' open-source CrossOver
26.3 release, plus [DXMT](https://github.com/3Shain/dxmt) for DirectX 10/11 and Apple's
D3DMetal for DirectX 11/12. Cellar sets them up, installs Windows Steam, shows your library
and launches each game with the right settings.

## Install

1. Download `Cellar.zip` from the [latest release](https://github.com/tigercommander131/cellar/releases/latest)
   and drag **Cellar** into Applications.
2. Open Cellar. It isn't signed with a paid Apple account, so macOS blocks it the first time. Go to
   **System Settings → Privacy & Security**, scroll down and click **Open Anyway**. You only do this
   once. (On some versions, **right-click Cellar → Open** also works.)
3. Click **Set Up**. Cellar checks your Mac, downloads about 1.5 GB, and installs Steam.
4. Sign in to Steam in the window that opens, install a game, and press **Play** in Cellar.

Needs macOS 26 or later, Apple Silicon, and Rosetta 2 (Cellar installs it if missing).
Steam's window stays closed while a game runs, which saves CPU, memory and battery. You can change
that in Settings.

## Steam, online or offline

Cellar checks whether Steam can really connect, whenever your network changes and before Steam starts.
On Wi-Fi that blocks Steam, like at school, it goes offline by itself so games still start, then goes back
online when it can. If a game is running, the switch waits until it closes. You can force either mode in
the Steam menu, top right, which also has shortcuts to Steam's store, downloads and friends.

## In a game

Press **Shift+Tab** to open Cellar's overlay. The game stays in view, with four tiles along the bottom:

- **Friends:** **Join** a friend's game or **Invite** them to yours. Join works in games that use Steam's
  lobbies; games with their own server browser are joined inside the game.
- **Clips:** **Option+C** saves the last 30 seconds (or up to 2 minutes), with sound, to Movies › Cellar
  Clips. Also screenshots. The Clips tab plays and trims them and shares them, by the share menu, by copy and
  paste or by dragging, and can make a copy under 10 MB. Cellar asks for macOS's Screen Recording permission once; after that
  Clips start with every game, unless you turn that off in Settings. Only your game is recorded.
- **Music:** control the Spotify app on your Mac, with cover art. macOS asks once whether Cellar can
  control it; there's no sign-in. A pop-up shows each new song during a game.
- **Game:** performance, recommended settings for your Mac, notes, and quitting the game.

Steam's own overlay stays off unless you switch it on for a game, under its advanced options.

Each game also has a **Best looks / Balanced / Battery saver** choice in its settings. Frame limits work on
DXMT games; on D3DMetal games, use the game's own limit or vsync.

## Menu bar

Cellar has its own icon in the menu bar, with Steam's status, your game, recent games, friends and music.
You can turn it off in Settings.

## Will it run?

Every game gets a badge: **Runs well**, **Should run**, **May struggle** or **Blocked**. Click it to see why.
It looks for anti-cheat in the game's files, what graphics it uses, and how it's gone on your Mac, and adds
[AreWeAntiCheatYet](https://areweanticheatyet.com), [ProtonDB](https://www.protondb.com) (Linux results, so
only a hint) and Steam's memory requirements. The search under All Games does the same for any game on Steam,
before you install it. Your own "It works" or "It doesn't" beats all of that.

If a game closes right after starting, Cellar asks whether to try another graphics option, and keeps the one
that works. It won't ask about games that already run on your Mac, or a graphics option you picked yourself.
You can turn this off in Settings.

## Spotlight and Siri

Type a game's name in Spotlight to start it, or say "Play Teardown in Cellar" to Siri. Also: "Save a clip in
Cellar", "Quit my game in Cellar", "Open Steam in Cellar". These work in the Shortcuts app too.

Cellar updates itself, and game fixes arrive automatically.

## What works

Single-player and VAC games. Games with kernel anti-cheat (most BattlEye and Easy Anti-Cheat
titles) won't run under Wine on any Mac.

## Command line

`Packages/CellarKit` builds a `cellar` tool that does everything the app does:

```
swift run --package-path Packages/CellarKit cellar status
swift run --package-path Packages/CellarKit cellar steam play 730
```

## Building

- App: `xcodegen generate && xcodebuild -scheme Cellar build` (Xcode 27, macOS 26 SDK).
- Engine: `engine/build.sh` (or the **Engine** GitHub Actions workflow).
- Release: `scripts/make-signing-cert.sh` once, then `scripts/release-app.sh <version> <build>`.
  `CHANNEL=beta` publishes to people who switched on beta versions only.

Trailers on the Games screen are Steam's own, silent, and stop while a game runs or Cellar isn't in front.

## License

Cellar's own code: [PolyForm Noncommercial 1.0.0](LICENSE). Free to use and share, never sold.

Third-party parts keep their licenses: the Sora typeface (SIL Open Font License, see `Cellar/Resources/Sora-OFL.txt`), Wine (LGPL-2.1+, source attached to each engine
release), DXMT (MIT), wine-mono, and the x86_64 libraries listed in
`engine/RELEASE-NOTES.md`. D3DMetal is Apple's and is never redistributed by Cellar: each Mac
downloads it from Gcenx's Game Porting Toolkit build during setup, under Apple's license.

Ideas, not code, came from Whisky, MacGames, Recall and Soju. Cellar is not affiliated with
CodeWeavers, Valve or Apple. CrossOver is a trademark of CodeWeavers, Inc.
