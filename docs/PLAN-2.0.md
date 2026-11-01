# Cellar 2.0: what was built, and what still needs a person

Built overnight on 2026-11-02 from Joel's picks. **Installed on Joel's Mac only, not released.** To release:

```
REPO=tigercommander131/cellar scripts/release-app.sh 2.0.0 5
```

## Decisions

| Topic | Decision |
|---|---|
| Online and offline | Automatic by default, with Always Online and Always Offline in the Steam menu |
| When it switches | Network changes, before Steam starts, every 5 minutes, and if Steam's log shows it stuck connecting. Never during a game |
| Overlay | Full-screen layer with Home, Friends, Clips, Performance and Game tabs |
| Clips | Off until switched on per session. Held in memory, H.264 from the media engine, up to 1080p60 |
| Recording area | The game's display without Cellar's windows. Frames are dropped while another Mac app is in front |
| Will It Run sources | The game's files, this Mac's history, the player's report, AreWeAntiCheatYet, ProtonDB, Steam's store |
| Reports | Stay on this Mac. Sharing them with the group needs a server, which wasn't decided |

## Proven

- The network check says "reachable" at home. Simulated blocked network: Steam goes offline by itself (closed or running), and a game starts offline in 15 seconds. Back online by itself, also with Steam running or closed.
- Shift+Tab opens the overlay over a real game (People Playground), tabs change with number keys, Esc closes it.
- A short test clip from the command line came out as valid H.264 video with AAC sound.
- Spotlight's index finds the game launchers.
- 40 automated tests pass.

## Not proven yet

1. **A real school network.** Blocked was simulated. The stuck-signing-in fallback has only run against sample logs.
2. **Clips inside the app.** They need Cellar's own Screen Recording permission, which only Joel can grant. Also Option+C, the HUD, and recording while a game is in front.
3. **Saying it to Siri,** and Spotlight's own game results. The App Intents data is in the app, but an ad-hoc signature may limit Siri.
4. **Join and Invite between two real players,** still open from 1.3.

## Morning checklist

1. Open Cellar, start a game, press Shift+Tab, go to Clips and switch them on. Allow Screen Recording, reopen Cellar, and try again.
2. Press Option+C in the game, then look in Clips.
3. Type a game's name in Spotlight.
4. Say "Play Teardown in Cellar" to Siri.
5. At school: open Cellar and press Play.

## Known limits

- Frame rate only shows while Clips are on, and tops out at 60, because it's measured from the recording.
- Ad-hoc signing means macOS may ask for Screen Recording again after each update.
- The Will It Run list covers installed games plus search. Steam's cached list can't prove what you own, and your profile's game list is private.
