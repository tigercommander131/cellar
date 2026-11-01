#!/usr/bin/env bash
# Rebuilds the small Windows helper that ships inside Cellar.app. Needs Homebrew's mingw-w64.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$(brew --prefix mingw-w64)/bin/x86_64-w64-mingw32-gcc" -O2 -Wall -s -o "$ROOT/Cellar/Resources/cellar-bridge.exe" "$ROOT/tools/bridge/cellar-bridge.c"
