# Cellar — build plan

A free, noncommercial macOS app for you and your friends that runs Windows Steam games on Apple Silicon. Cellar is the front-end. The engine is CodeWeavers' open-source CrossOver Wine, which we compile ourselves; we don't write it.

Status: **plan only, no code yet.** Once you give the go-ahead, I build straight through to a working v1.

---

## Decisions

| Topic | Decision |
|---|---|
| Name | **Cellar** |
| Who uses it | You and your friends. Free and noncommercial |
| Repo | **Public**: `github.com/tigercommander131/cellar` |
| License | **PolyForm Noncommercial 1.0.0** (free to use and share, never sold). This also lets us reuse MacGames code legally, with their required notice. Wine stays LGPL, with its source published next to every engine build |
| Macs | Apple Silicon only, **macOS 26 Tahoe or later**. One build for everyone |
| RAM | One build with a RAM check: Macs with 8 GB get **low-memory mode** automatically (see below) |
| UI | **SwiftUI**. Visual design drawn from **Mobbin** references once the engine works |
| First run | **One-click setup.** Bottles, engines and backends sit in an Advanced tab |
| Game sources | **Steam only** for v1 |
| Features | **Working and stable first.** No extras in v1 (raw mouse, controllers, MetalFX, shortcuts and debug reports are all later) |
| Engine | **CrossOver 26.3.0 Wine built from source on GitHub Actions** and published as a release |
| Graphics | **D3DMetal 3.0** for DX12, **DXMT v0.80** for DX10/11, WineD3D as fallback |
| D3DMetal handling | **Never uploaded by us.** Each Mac downloads Gcenx's public `game-porting-toolkit-3.0-3` during setup and extracts only the D3DMetal files on that Mac |
| Updates | **Auto-update**: Sparkle 2 for the app (EdDSA-signed, no Apple account needed), plus engine and game-fix packs from GitHub releases |
| Game fixes | **You curate.** Profiles ship as a pack that everyone's Cellar picks up automatically |
| Signing | **Ad-hoc signed, no paid Apple account.** Friends right-click → Open the first time; the README shows how |
| First games | **One More Lawn (demo)** on DX12 and **Counter-Strike 2** on DX11, then more DX12 games like One More Lawn |
| Workflow | **Straight through to v1.** I stop only when truly blocked (see "When I'll need you") |

### Why Apple Silicon needs an "Intel" engine
Wine on macOS is still compiled as an x86_64 (Intel) program, and it runs on M-series Macs through Rosetta 2. The Windows games are Intel code too, so Rosetta translates everything anyway. That's how CrossOver and Whisky work on M1–M5. Cellar itself is a native Apple Silicon app. When Apple limits Rosetta in macOS 28, we swap the engine pack for ARM64 Wine with FEX; the app stays the same.

---

## How it fits together

```
github.com/tigercommander131/cellar
├── Cellar/                 SwiftUI app (macOS 26+, arm64)
├── CellarCLI/              `cellar` command-line tool, so I can test everything headless
├── Packages/CellarKit/     All logic, shared by the app and CLI, unit-tested
├── engine/                 Build scripts + patches for the CrossOver 26.3 Wine engine
├── profiles/               Per-game JSON profiles (shipped as a pack)
├── .github/workflows/
│   ├── engine.yml          Builds the engine on a Mac runner, publishes engine-cx26.3-N + its source
│   ├── profiles.yml        Packs profiles/ into a release when they change
│   └── app.yml             Builds Cellar.app, signs the Sparkle update, updates appcast.xml
└── packs.json              Manifest: every pack's URL + SHA-256 (fetched by every Cellar)
```

### What each Mac downloads during setup

| Pack | Source | Notes |
|---|---|---|
| Engine (CX 26.3 Wine) | Our GitHub release | Built by `engine.yml`. Source tarball and patches attached to the same release (LGPL) |
| DXMT v0.80 | `3Shain/dxmt` release `dxmt-v0.80-builtin.tar.gz` | MIT. Installed into the engine's `lib/dxmt` |
| D3DMetal 3.0 | `Gcenx/game-porting-toolkit` release `3.0-3` | Apple's license. Only the D3DMetal parts are extracted, on the user's own Mac |
| Profiles | Our GitHub release | The curated game fixes |
| Steam | Valve's `SteamSetup.exe` | Not SHA-pinned, because Valve updates it in place |

Every download goes through the same steps:
1. Download with URLSession and check the SHA-256 from `packs.json` (except Steam's installer).
2. Unpack into a staging folder.
3. Strip quarantine flags.
4. Atomically swap into place.

We never edit a signed binary after signing it.

### On-disk layout (each Mac)

```
~/Library/Application Support/Cellar/
├── packs/{engine,dxmt,d3dmetal,profiles}-<version>/
├── bottles/steam/           shared WINEPREFIX: Steam + games
├── cache/                   downloads, artwork, shader caches
├── logs/                    per-session logs, kept for 7 days
└── state.json
```

### Launch: environment variables and DLL overrides

Before launching, Cellar strips any inherited `WINE*`, `DYLD_*`, `DXMT_*`, `MTL_*`, `D3DM_*` and `CX_*` variables, then sets:

```
WINEPREFIX  WINESERVER  WINELOADER   (point into the engine pack and bottle)
WINEDEBUG=-all  WINEMSYNC=1  WINEESYNC=0  ROSETTA_ADVERTISE_AVX=1
WINEDLLOVERRIDES base: winemenubuilder.exe=;gameoverlayrenderer,gameoverlayrenderer64=
```

| Backend | `WINEDLLPATH` | Extra overrides | Extra env |
|---|---|---|---|
| D3DMetal (DX12, DX11) | `<d3dmetal>/wine:<engine>/lib/wine` | `dxgi,d3d11,d3d12,atidxx64=n,b;nvapi64,nvngx=` | `CX_APPLEGPTK_LIBD3DSHARED_PATH=<d3dmetal>/external/libd3dshared.dylib` |
| DXMT (DX10/11) | `<engine>/lib/dxmt:<engine>/lib/wine` | `dxgi,d3d11,d3d10core,winemetal=b;d3d12,nvapi64,nvngx=` | `CX_GRAPHICS_BACKEND=dxmt`, `DXMT_SHADER_CACHE_PATH`, `DXMT_LOG_LEVEL=error` |
| WineD3D | `<engine>/lib/wine` | `nvapi64,nvngx=` | none |

Processes run through `Foundation.Process`, with output appended to log files. Running games are found with `proc_listallpids`. Stopping runs `wineserver -k` then `wineserver -w`, also on app quit or after a hang timeout.

### Steam
- **Install:** `wine SteamSetup.exe /S` into the shared bottle. **Each person signs in themselves** in Steam's own window, including Steam Guard.
- **Play:** `steam.exe -cef-disable-gpu [-no-cef-sandbox] -applaunch <appid>`.
  - Steam passes its environment to every game it launches, so Cellar hashes the environment the game needs and restarts Steam first if that changed, but never while a game is running.
- **Library:**
  - Parse `libraryfolders.vdf` and `appmanifest_*.acf` (Valve's text format).
  - Installed means `StateFlags & 4`.
  - Steam is ready when `console_log.txt` shows "System startup time:". A game is alive when `gameprocess_log.txt` shows "AppID X adding PID".
- **Artwork:** Steam's `IStoreBrowseService/GetItems` API, falling back to the CDN's `library_600x900.jpg` and `library_hero.jpg`. Cached on disk.
- **Black-window workarounds** for Steam's built-in browser, in order: `-cef-disable-gpu`, then `-no-cef-sandbox`, then turning off GPU web rendering in Steam's settings. Whichever works becomes the default.

### RAM check (one build for everyone)
On launch Cellar reads the RAM size. **8 GB Macs get low-memory mode**, which is on by default and can be turned off:
- Steam starts with `-silent`, and its window closes once a game is running.
- A warning shows before launching a game whose profile says `minRAMGB: 16`.
- Shader-cache prewarming is limited.

16 GB Macs get normal mode.

### Game profiles (JSON, keyed by Steam app ID)

```json
{
  "appId": "730",
  "title": "Counter-Strike 2",
  "graphics": "dxmt",
  "windowsVersion": "win10",
  "minRAMGB": 8,
  "env": { "DXMT_CS2_EARLY_COMPILE": "1" },
  "dllOverrides": {},
  "steamArgs": [],
  "gameArgs": [],
  "registry": [],
  "notes": "VAC only, so it's fine under Wine."
}
```

Games without a profile get defaults: D3DMetal, win10, shared bottle. The Advanced tab can override per game on one Mac.

---

## Build order (straight through, no check-ins)

Every step ends with a check I run myself (CLI output, logs, screenshots of the app) before moving on.

1. **Repo and CI skeleton.** Create `tigercommander131/cellar` (public), add the license, README with the right-click → Open guide, and the Xcode project via XcodeGen with app, CLI and CellarKit targets.
2. **Engine on GitHub Actions** (the hardest part).
   - `engine.yml` downloads `crossover-sources-26.3.0.tar.gz` and builds the `sources/wine` folder for x86_64 using Recall's documented recipe (Soju recipe) and `llvm-mingw` for the Windows-side DLLs.
   - It runs on GitHub's Intel macOS runner (`macos-15-intel`, to be confirmed) or an ARM runner under Rosetta.
   - It publishes `engine-cx26.3-1` with the source and patches attached.
   - **Check:** `wine --version` and `winecfg` run on this Mac, and DX11 and DX12 samples render through DXMT and D3DMetal.
   - **Debug reference:** MacGames' published `runtime-4` (also a CX 26.3 build) is used only to compare when ours misbehaves.
3. **CellarKit and CLI.**
   - Packs: manifest, download, verify, install.
   - Checks for Rosetta, disk space and RAM.
   - Bottles: `wineboot --init`, waiting until `system.reg` exists, then `winecfg -v win10`, real folders in place of home-folder links, and `z:` remapped away from `/`.
   - Environment and graphics wiring, process runner, logs, stop.
   - Unit tests in Swift Testing.
   - **Check:** `cellar run` launches a Windows exe on each backend.
4. **Steam.**
   - CLI commands `cellar steam install|launch|list`, the VDF parser, environment fingerprint and restart, readiness detection, and finding the working black-window workaround.
   - **Check:** Steam opens, then **you sign in once**. The One More Lawn demo installs and launches from the CLI.
5. **App UI.**
   - Pull launcher and library references from **Mobbin** (screens and flows for game libraries, onboarding and settings) and settle on a look.
   - Then build the one-click setup wizard, the library grid with artwork, Play/Stop, install progress, the Advanced tab and the low-memory toggle.
   - **Check:** first-run setup completes from a clean state, and both games launch with one click.
6. **Profiles.**
   - Tune and ship profiles for the One More Lawn demo (D3DMetal) and CS2 (DXMT).
   - Look up One More Lawn's Steam app ID from its store page.
   - Add a few similar DX12 games (I'll suggest some; you pick).
7. **Updates and release.**
   - Sparkle appcast, `app.yml` and `profiles.yml`, and the `packs.json` publishing flow.
   - **Check:** an older build auto-updates to a newer one on this Mac, without Gatekeeper blocking it.
   - Publish **v1.0**.

### When I'll need you
- **Empty the Trash** before step 2 (about 82 GB waiting there).
- **Sign into Steam** in step 4. I can't type passwords for you.
- **Pick extra DX12 games** in step 6.
- **CS2 download:** it's about 60 GB, so it takes a while; I'll schedule it after One More Lawn works.
- **Truly stuck:** if the engine build fails in a way I can't fix from the logs, I'll come back with what I tried and the options.

Your go-ahead on this plan covers creating the public repo on `tigercommander131` and pushing to it as I build.

---

## After v1 (not now)
- "Copy debug report" button for friends.
- Raw mouse input for shooters (Recall's patch), controllers, MetalFX and FPS HUD toggles.
- Dock/Launchpad shortcuts per game with Game Mode.
- Non-Steam `.exe` games, Epic, Battle.net.
- Winetricks verbs, D3DMetal 4 when it's packaged, DXMT 1.0, ARM64 Wine + FEX before macOS 28.

## Risks

| Risk | Mitigation |
|---|---|
| Engine build fails or takes many tries | Build logs are public in Actions. Compare with MacGames' runtime-4. Recall's recipe is known to work |
| GitHub's Intel macOS runner is unavailable | Use an ARM runner with Rosetta. Last resort: build on this Mac |
| Steam's browser window renders black, or Steam updates break it | Several workarounds in order. Readiness is detected from logs, not the UI |
| Sparkle updates of an ad-hoc-signed app get blocked by Gatekeeper | Tested in step 7. Fallback: Sparkle's installer clears quarantine, plus a README note |
| 8 GB friends' Macs and heavy DX12 games | Low-memory mode and `minRAMGB` warnings. Some games just won't fit |
| Cold Turkey Blocker on your Mac | If Steam can't connect, check its block list first |
| Kernel anti-cheat (BattlEye, EAC without Wine support) | Out of scope. Noted in profiles |
