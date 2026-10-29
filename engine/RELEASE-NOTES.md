Cellar's Wine engine, built from CodeWeavers' open-source CrossOver 26.3.0 release
(`crossover-sources-26.3.0.tar.gz`, `sources/wine`) by `engine/build.sh`.

- `cellar-engine-*.tar.xz`: the engine (x86_64; runs on Apple silicon through Rosetta 2).
- `crossover-sources-26.3.0.tar.gz`: the corresponding Wine source, unmodified from CodeWeavers.
- `cellar-engine-*-patches.tar.gz`: Cellar's build script and patches.

Wine is LGPL-2.1-or-later. The bundled x86_64 libraries (GnuTLS, MoltenVK, SDL2 …) come from
frankea/Whisky's `Libraries.tar.gz` v3.1.1 (GPL), whose sources are listed in that project.
wine-mono 10.4.1 is the official wine-mono release.

Cellar is not affiliated with CodeWeavers. CrossOver is a trademark of CodeWeavers, Inc.
D3DMetal is never included: each Mac downloads it from Gcenx's Game Porting Toolkit build during setup.
