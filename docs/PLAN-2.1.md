# Cellar 2.1 plan: music, menu bar, self-fixing games

Status: **released to everyone on 2026-11-02** as 2.1.0 (build 7), after Joel confirmed the Music tab and clip trimming work.

2.1.1 (build 8) is on Joel's Mac only, not released: a fix for the trim screen crash, quick-length trim buttons, and the overlay closing when you swipe desktops. To release: `REPO=tigercommander131/cellar scripts/release-app.sh 2.1.1 8`

## Decisions

| Topic | Decision |
|---|---|
| Spotify | Controls the Spotify app on the Mac. No sign-in, and no browsing playlists from Cellar |
| Menu music | None. Cellar never starts or stops music by itself |
| In a game | Music tab in the overlay, a small player on its Home tab, and a pop-up when the song changes |
| After a game | Spotify carries on playing |
| Menu bar | Cellar's own icon: Steam status, the running game, recent games, friends, music, shortcuts |
| Self-fixing | A game that closes within 20 seconds is retried on the next graphics option that suits it. What works is remembered. A graphics option you chose yourself is left alone |
| Beta channel | A switch in Settings. Beta releases sit in the same update feed, and older Cellars ignore them |
| Lasting permission | Sign with a stable self-made certificate, so macOS should keep Screen Recording across updates |
| Clip trimming | Inside the overlay's Clips tab. Saves a new file and keeps the original |
| Not included | The on-top window fix (Joel: hold off), video and controllers, Cool Mode, Tonight, mods |

## The riskiest part

Your mates are on ad-hoc signed 2.0. Moving to a certificate must not break their auto-update, or they'd be stuck. **Update from a real 2.0 to 2.1 gets tested before any release.**

## Proven

- A real, ad-hoc signed 2.0 from GitHub updated to the signed 2.1 through a local test feed and relaunched.
- 2.0 ignores a beta-tagged update. 2.1 ignores it with the switch off and offers it with the switch on.
- Self-fixing on People Playground: retried on DXMT and kept it, and restored the settings when everything failed.
- The Steam offline switch and a game starting, on a network that really blocks Steam.
- A trim of a real clip gave the right length with video and sound. The overlay's small player showed the current song from Spotify's notifications.

## Not proven yet

1. Screen Recording surviving an update. The signature is stable, but that takes a real grant and a later update.
2. A fresh download of the certificate-signed app. It should behave as before (Open Anyway), but only updating was tested.

## Limits to expect

- Controlling Spotify needs macOS's Automation permission once. Song names and the pop-up work without it.
- Beta covers app updates. New engines still go to everyone.
