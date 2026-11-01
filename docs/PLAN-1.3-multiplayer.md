# Cellar 1.3 plan: easy multiplayer, overlay, performance, settings

Status: **shipped as Cellar 1.3.** Changes from this plan: the real Steam overlay worked in One More Lawn, but Joel chose Cellar's overlay as the main one, so Steam's is an off-by-default Advanced switch. Not yet tested: Join and Invite between two real players, and Nuclear Option on DXMT vs D3DMetal.

**Goal:** one-click Join and Invite in games that support it, a stable overlay, smoother games, and more settings, without making the app harder to use.

## What "any game" can honestly mean

| Kind of game | Join / Invite from Cellar? |
|---|---|
| Uses Steam lobbies or Steam's "connect" info (most Steam co-op, likely One More Lawn) | **Yes, if the tests below pass** |
| Own server browser or join codes (Nuclear Option is a game to check) | Join only if it publishes Steam join info. Otherwise it's joined inside the game |
| Needs a non-Steam account (EA, Epic) | Inside the game only |
| Kernel anti-cheat (Siege, Destiny 2, likely Squad) | No, Wine is blocked |

Join shows only when a friend's game can really be joined. Otherwise the row says "Playing X" with a Chat button.

## Decisions

| Topic | Decision |
|---|---|
| One click | **Join** button on friends; **Invite** from the overlay |
| Overlay | **Cellar's overlay always available**, plus the real Steam overlay per game where tests show it's stable |
| Hotkey | **Shift+Tab**, changeable. On games using the real Steam overlay, Steam keeps it |
| Performance | Engine stutter fixes, Quality / Balanced / Battery presets, hide Steam while playing |
| Settings | Preset, plus an Advanced section |
| On battery | **Ask at launch** (with "don't ask again") |
| First games | Nuclear Option, One More Lawn, Gamble With Your Friends |
| Rollout | **Straight to everyone** (see Risks: Join can't be fully proven without a second account) |
| Bug fixes included | Auto-update proof, reliable Running status, safe links, blank covers, window dragging |
| Not included | Video playback and controllers, Play Together, Mac notifications, MetalFX |
| Order | **Prove the risky parts first** |

## What the research showed

- **Join links:** Steam's own client code (`ConnectToFriendsGame`) builds `steam://joinlobby/<app>/<lobby>/<friend>`, or `steam://rungame/<app>/<friend>/<connect>`. Cellar can send the same links to Windows Steam.
- **Friend lobby data:** Steam's friends API has `GetFriendGamePlayed` (includes the lobby) and `GetFriendRichPresence("connect")`. Public profiles alone don't give us this. The API also has `InviteUserToGame` and `InviteUserToLobby`.
- **Real overlay:** Cellar blocks it today (`gameoverlayrenderer` is disabled in `Wine.swift`). One CrossOver forum user reported it working on DXMT but not D3DMetal; that's a single report, and I could only read a search summary of it. Cellar's single-process Steam fix may also interfere.
- **Performance:**
  - Recall documents fixes for a Wine pause of about 100 ms every 30 s and for 150–400 ms freezes during DLL loads.
  - DXMT has `d3d11.preferredMaxFrameRate`.
  - **No frame cap is known for D3DMetal yet**, and that's what your priority games use. Nuclear Option is DirectX 11, so it can be tried on DXMT. One More Lawn uses DirectX 12, so it stays on D3DMetal.

## Step 0: Prove the risky parts (short, single runs, stop everything after)

Each result decides what gets built.

| Test | Pass means | If it fails |
|---|---|---|
| **A. Auto-update:** install an older Cellar and update to 1.2 | Rollouts work | Fix the updater first. Anyone stuck reinstalls once |
| **B. Steam helper:** tiny Windows program reads friends, game, lobby and connect info from the running Steam | Join and Invite are buildable | Keep public-profile status. Join opens Steam's friends window instead (2–3 clicks) |
| **C. Invite call:** run from the helper in a real lobby; check the return value | Invite is likely to work; only a second account proves delivery | Invite button opens Steam's friends window |
| **D. Real overlay:** Nuclear Option, One More Lawn and Gamble With Your Friends, on each backend that applies | Overlay allowed for that game | Cellar's overlay only for that game |
| **E. Cellar's panel over a fullscreen game:** does it appear, can the mouse be used, does the game survive? | Overlay design stands | Try a small Wine change, or fall back to windowed use |
| **F. Nuclear Option on DXMT vs D3DMetal** with the FPS counter | Pick the faster default | Keep D3DMetal |

## Step 1: Foundations

- **Running status:** check real game processes, not Steam's log. Join, Invite and auto-off all depend on this.
- **Safe links:** `cellar://` and join links accept only strict formats, and `cellar://play` only installed games.
- **Covers:** failed lookups retry instead of being saved forever.
- **Window dragging:** drag by the top bar.
- **Nuclear Option:** Cellar writes `steam_appid.txt` for games whose profile asks for it (the fix I did by hand).

## Step 2: Join and Invite

- **Helper:** `cellar-bridge.exe`, small, ships with the app, and talks to the Steam client already running. Runs only while the Friends tab or overlay is open, to save battery.
- **Join flow:**
  1. Click **Join**.
  2. If the game isn't installed, offer to install it.
  3. If another game is running, ask to close it first.
  4. If Steam needs different settings, restart it.
  5. Send the join link.
- **Invite:** while playing, click Invite next to a friend in the overlay.
- **Offline mode:** Join and Invite are replaced by "Go Online".
- **Fallback:** if anything fails, say so plainly and open Steam's friends window.
- **LAN games:** add the macOS Local Network permission text to the game bundles, or LAN discovery can fail silently.

## Step 3: Overlay

- **Cellar's overlay:** a native side panel, opened with Shift+Tab, showing friends with Join and Invite, the current game, and Force Quit. The hotkey is active only while a game is running.
- **Real Steam overlay:** on per game, only for games that passed test D. If a game with it on closes within about 20 seconds, Cellar turns it off for that game and tells you.
- **Known limit:** where the real overlay is off, a game's own "Invite" button still does nothing. Cellar's panel does the inviting instead.

## Step 4: Performance and settings

- **Engine revision 4 (cloud build):** adapt Recall's stutter fixes after reading exactly what they change, with credit (Apache-2.0).
- **Presets,** using cards like [hilos' preferences](https://mobbin.com/screens/97a1d5b5-5273-40cf-9587-b0360cb38827):

| Preset | Frame cap (DXMT only unless a D3DMetal option turns up) | Retina | Steam window |
|---|---|---|---|
| Quality | None | Per game | Hidden while playing |
| Balanced | 60 | Off | Hidden |
| Battery | 30 | Off | Hidden |

  If a game's backend can't cap frames, its settings say so and point to the in-game limit or vsync.

- **Battery prompt:** pressing Play while unplugged asks "Use Battery preset?", with "don't ask again".
- **Advanced section,** with rows like [Plain's settings](https://mobbin.com/screens/6f315240-783e-460f-a698-2d79df004546): graphics backend, frame cap, Retina, Steam overlay, FPS counter, launch options, hide Steam.
- **Friends and overlay layout:** based on [Discord's friends list](https://mobbin.com/screens/d90f0321-2de7-4f40-aa08-d810704bb630): status rows with actions on the right, "Playing now" first.

## Step 5: Check and release

- Unit tests for link parsing, the helper's output and presets.
- One combined pass through the app, then stop everything to keep your Mac cool.
- Release as Cellar 1.3 to everyone, with engine revision 4 and game profiles for the three priority games.
- Leave a short test checklist for the first time a mate is online.

## Risks

1. **Join and invite delivery can't be fully proven with one account.** I can prove the data and links, but not a friend actually landing in your lobby. Since rollout goes straight to everyone, the first real test happens live. The fallback to Steam's friends window limits the damage. A free second Steam account would close this gap, but you'd have to create it and it means running two Steams on your Mac for a short test.
2. **The real Steam overlay may fail on all three games.** Then 1.3 ships with Cellar's overlay only, and in-game Invite buttons stay dead.
3. **Cursor capture:** a game holding the mouse may fight Cellar's panel. Test E exists for this.
4. **D3DMetal may have no frame cap,** so the Battery preset does less on those games.
5. **Steam updates** can change things. The helper uses Steam's long-standing friends API rather than its web UI, to reduce this.

## Sources

- [DXMT config](https://github.com/3Shain/dxmt/blob/main/dxmt.conf)
- [ISteamFriends API](https://partner.steamgames.com/doc/api/ISteamFriends)
- [CodeWeavers Steam forum](https://www.codeweavers.com/compatibility/crossover/forum/steam/store.steampowered.com?msg=332688) (search summary only; the page itself refused the fetch)
- Steam client files on this Mac (`steamui`)
- Recall's `docs/HOW-IT-WORKS.md` and `patches/README.md`
