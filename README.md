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

## In a game

Press **Shift+Tab** to open Cellar's overlay: see who's online, **Join** a friend's game, **Invite**
friends to yours, or Force Quit. Friends also have a Join button in the Friends tab. Join works in games
that use Steam's lobbies; games with their own server browser are joined inside the game. Steam's own
overlay stays off unless you switch it on for a game, in its settings, under Advanced.

Each game also has a **Quality / Balanced / Battery** preset. Frame limits work on DXMT games; on
D3DMetal games, use the game's own limit or vsync.

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

## License

Cellar's own code: [PolyForm Noncommercial 1.0.0](LICENSE). Free to use and share, never sold.

Third-party parts keep their licenses: Wine (LGPL-2.1+, source attached to each engine
release), DXMT (MIT), wine-mono, and the x86_64 libraries listed in
`engine/RELEASE-NOTES.md`. D3DMetal is Apple's and is never redistributed by Cellar: each Mac
downloads it from Gcenx's Game Porting Toolkit build during setup, under Apple's license.

Ideas, not code, came from Whisky, MacGames, Recall and Soju. Cellar is not affiliated with
CodeWeavers, Valve or Apple. CrossOver is a trademark of CodeWeavers, Inc.
