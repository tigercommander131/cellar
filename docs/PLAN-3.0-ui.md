# Cellar 3.0: the overhaul

Status: **on Joel's Mac only, not released.** Prototypes: [Cellar Redesign Directions](https://claude.ai/artifact/GQEWDbxUqyfTYPdZtnK9UB) (private).

## Decisions

| Topic | Decision |
|---|---|
| Look | A: Console. Full-screen art, big covers |
| Overlay | A: bottom strip with Friends, Clips, Music, Game. Performance moved into Game |
| Main screens | Home and Library merged into Games. All Games is a tile on the shelf |
| Game settings | Three choices and recommendations. The rest behind Show Advanced |
| Settings | Inside the app, sidebar with five categories |
| Colour | White controls, colour from game art |
| Trailers | Silent, whenever online. Off while a game runs or Cellar isn't in front, on a switch in Settings |
| Friends | Own tab, plus up to four in the corner of Games |
| Logo | A white tulip glass of red wine on a wine-red tile, with a lowercase `cellar` wordmark in Sora |

References from Mobbin: Apple Games and Xbox for the console feel, Linear and Buffer for settings.

## To release

1. In `packs.json`, change the engine's version, URL and `archiveRoot` to `cx26.3.0-5`, and push. The Packs workflow publishes it.
2. `REPO=tigercommander131/cellar scripts/release-app.sh 3.0.0 15` (bump the build if the app has changed since).
3. `defaults delete com.tigercommander131.cellar manifestURL` on Joel's Mac, which currently uses `.work/packs-r5.json`.

## Not proven yet

- Trailers in the real window. The stream itself plays, but the test windows don't count as in front.
- The overlay's bottom strip over a real game, including true fullscreen, and its buttons.
- Trim screen inside the smaller panel.
