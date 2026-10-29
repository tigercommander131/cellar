#!/usr/bin/env bash
# Builds Cellar's Wine engine from CodeWeavers' open-source CrossOver release.
#
# Wine on macOS is an x86_64 program that runs on Apple Silicon through Rosetta 2,
# so everything here is compiled for x86_64 (`arch -x86_64`), while the build
# tools themselves (bison, mingw-w64) come from the normal arm64 Homebrew.
#
# Usage: engine/build.sh [download|build|package|all]   (default: all)
# Env:   WORK (default .work), JOBS (default: CPU count), ENGINE_REVISION (default 1)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-$ROOT/.work}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
REVISION="${ENGINE_REVISION:-1}"
CX_VERSION="26.3.0"
NAME="cellar-engine-cx${CX_VERSION}-${REVISION}"

DL="$WORK/downloads"
SRC="$WORK/src"
DEPS="$WORK/deps"
BUILD="$WORK/wine-build"
STAGE="$WORK/stage/$NAME"
DIST="$WORK/dist"

# name|url|sha256
SOURCES=(
  "crossover-sources-${CX_VERSION}.tar.gz|https://media.codeweavers.com/pub/crossover/source/crossover-sources-${CX_VERSION}.tar.gz|ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872"
  "freetype-2.13.3.tar.gz|https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.gz|5c3a8e78f7b24c20b25b54ee575d6daa40007a5f4eea2845861c3409b3021747"
  "wine-mono-10.4.1-x86.tar.xz|https://github.com/wine-mono/wine-mono/releases/download/wine-mono-10.4.1/wine-mono-10.4.1-x86.tar.xz|a16606ef0724202e6a6848ece6e0cbba64d11e2f11aefe744af1d93c6d9f99bb"
  "whisky-libraries-3.1.1.tar.gz|https://github.com/frankea/Whisky/releases/download/v3.1.1/Libraries.tar.gz|01f3a1b43b98065fe20c529c1023b61dd79a6d2ad93bba6040865f646481ccf3"
)

log() { printf '\n==> %s\n' "$*"; }

need_tools() {
  local missing=()
  for f in bison mingw-w64; do brew list "$f" >/dev/null 2>&1 || missing+=("$f"); done
  [ ${#missing[@]} -eq 0 ] || brew install "${missing[@]}"
  arch -x86_64 /usr/bin/true || { echo "Rosetta 2 is required: softwareupdate --install-rosetta --agree-to-license" >&2; exit 1; }
  export PATH="$(brew --prefix bison)/bin:$(brew --prefix)/bin:$PATH"
}

download() {
  mkdir -p "$DL"
  for entry in "${SOURCES[@]}"; do
    IFS='|' read -r file url sha <<<"$entry"
    if [ ! -f "$DL/$file" ]; then
      log "Downloading $file"
      curl -fL --retry 3 -o "$DL/$file.part" "$url"
      mv -f "$DL/$file.part" "$DL/$file"
    fi
    echo "$sha  $DL/$file" | shasum -a 256 -c - >/dev/null || { echo "Checksum mismatch: $file" >&2; exit 1; }
  done
}

prepare_sources() {
  log "Extracting Wine from the CrossOver source"
  rm -rf "$SRC"; mkdir -p "$SRC"
  tar -xzf "$DL/crossover-sources-${CX_VERSION}.tar.gz" -C "$SRC" sources/wine
  local p
  for p in "$ROOT"/engine/patches/*.patch; do
    [ -e "$p" ] || continue
    log "Applying $(basename "$p")"
    patch -p1 --forward -d "$SRC/sources/wine" < "$p"
  done
}

build_deps() {
  rm -rf "$DEPS" "$WORK/freetype-2.13.3" "$WORK/whisky-libs"; mkdir -p "$DEPS/lib" "$WORK/whisky-libs"

  # GnuTLS, MoltenVK, SDL2 etc. as x86_64 dylibs (frankea/Whisky, GPL). Their install
  # names are bare ("libgnutls.30.dylib"); Wine finds them through DYLD_FALLBACK_LIBRARY_PATH.
  log "Collecting x86_64 runtime libraries (GnuTLS, MoltenVK, ...)"
  tar -xzf "$DL/whisky-libraries-3.1.1.tar.gz" -C "$WORK/whisky-libs"
  find "$WORK/whisky-libs/Libraries/Wine/lib" -maxdepth 1 -name '*.dylib' ! -name 'libfreetype*' -exec cp -fP {} "$DEPS/lib/" \;
  ls "$DEPS/lib/libgnutls.30.dylib" "$DEPS/lib/libMoltenVK.dylib" >/dev/null

  # Our own FreeType, with an absolute install name so Wine's build tools can run it.
  log "Building x86_64 FreeType"
  tar -xzf "$DL/freetype-2.13.3.tar.gz" -C "$WORK"
  ( cd "$WORK/freetype-2.13.3" \
    && arch -x86_64 ./configure --prefix="$DEPS" --enable-shared --disable-static \
         --without-harfbuzz --without-png --without-brotli --without-bzip2 --without-zlib \
         CC="clang -arch x86_64" >/dev/null \
    && arch -x86_64 make -j"$JOBS" >/dev/null 2>&1 && arch -x86_64 make install >/dev/null )
}

build_wine() {
  log "Configuring Wine (x86_64 host, i386 + x86_64 PE)"
  rm -rf "$BUILD"; mkdir -p "$BUILD"
  local brew_prefix; brew_prefix="$(brew --prefix)"
  ( cd "$BUILD" && arch -x86_64 "$SRC/sources/wine/configure" \
      --enable-archs=i386,x86_64 --without-x --disable-tests --prefix=/usr/local \
      FREETYPE_CFLAGS="-I$DEPS/include/freetype2" FREETYPE_LIBS="-L$DEPS/lib -lfreetype" \
      GNUTLS_CFLAGS="-I$brew_prefix/include" GNUTLS_LIBS="-L$DEPS/lib -lgnutls" \
      LDFLAGS="-L$DEPS/lib" CC="clang -arch x86_64" CXX="clang++ -arch x86_64" \
      > "$WORK/configure.log" 2>&1 ) || { tail -40 "$WORK/configure.log"; exit 1; }
  grep -E '^configure: (WARNING|error)' "$WORK/configure.log" || true
  # configure records library names from the build machine; pin the names the engine ships.
  sed -i '' -e 's|#define SONAME_LIBGNUTLS .*|#define SONAME_LIBGNUTLS "libgnutls.30.dylib"|' \
            -e 's|#define SONAME_LIBFREETYPE .*|#define SONAME_LIBFREETYPE "libfreetype.6.dylib"|' "$BUILD/include/config.h"
  grep -E '#define SONAME_' "$BUILD/include/config.h"

  compile_wine
}

compile_wine() {
  log "Compiling Wine with $JOBS jobs (this takes a while)"
  ( cd "$BUILD" && arch -x86_64 make -j"$JOBS" > "$WORK/make.log" 2>&1 ) || { tail -60 "$WORK/make.log"; exit 1; }
  rm -rf "$WORK/install"
  ( cd "$BUILD" && arch -x86_64 make install DESTDIR="$WORK/install" > "$WORK/install.log" 2>&1 )
}

package() {
  log "Assembling $NAME"
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp -Rc "$WORK/install/usr/local/." "$STAGE/"
  cp -cP "$DEPS/lib/"*.dylib "$STAGE/lib/"
  mkdir -p "$STAGE/share/wine/mono"
  tar -xJf "$DL/wine-mono-10.4.1-x86.tar.xz" -C "$STAGE/share/wine/mono"
  rm -rf "$STAGE/share/man" "$STAGE/include" "$STAGE/share/applications"

  log "Slimming (developer tools, import libraries, debug info)"
  local t
  for t in function_grep.pl widl winebuild winecpp winedump wineg++ winegcc winemaker wmc wrc; do rm -f "$STAGE/bin/$t"; done
  find "$STAGE/lib/wine" -name '*.a' -delete
  local brew_bin; brew_bin="$(brew --prefix mingw-w64)/bin"
  find "$STAGE/lib/wine/x86_64-windows" -type f \( -name '*.dll' -o -name '*.exe' -o -name '*.drv' -o -name '*.sys' -o -name '*.ocx' -o -name '*.cpl' -o -name '*.acm' -o -name '*.ax' -o -name '*.tlb' -o -name '*.ds' \) \
    -exec "$brew_bin/x86_64-w64-mingw32-strip" --strip-debug {} + 2>/dev/null || true
  find "$STAGE/lib/wine/i386-windows" -type f \( -name '*.dll' -o -name '*.exe' -o -name '*.drv' -o -name '*.sys' -o -name '*.ocx' -o -name '*.cpl' -o -name '*.acm' -o -name '*.ax' -o -name '*.tlb' -o -name '*.ds' \) \
    -exec "$brew_bin/i686-w64-mingw32-strip" --strip-debug {} + 2>/dev/null || true
  find "$STAGE/lib/wine/x86_64-unix" -type f -name '*.so' -exec strip -S {} + 2>/dev/null || true
  strip -S "$STAGE/bin/wine" "$STAGE/bin/wineserver" "$STAGE/bin/wine-preloader" 2>/dev/null || true
  du -sh "$STAGE"

  # Wine needs to map executable memory and load unsigned Windows-side code.
  local ent="$WORK/wine.entitlements"
  cat > "$ent" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
  <key>com.apple.security.cs.disable-executable-page-protection</key><true/>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
  <key>com.apple.security.cs.allow-jit</key><true/>
  <key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
PLIST
  local b
  for b in wine wineserver wine-preloader wine64 wine64-preloader; do
    [ -f "$STAGE/bin/$b" ] || continue
    install_name_tool -add_rpath "@loader_path/../lib" "$STAGE/bin/$b" 2>/dev/null || true
    codesign -f -s - --entitlements "$ent" "$STAGE/bin/$b"
  done

  cat > "$STAGE/CELLAR-ENGINE.json" <<JSON
{
  "name": "$NAME",
  "wine": "$("$STAGE/bin/wine" --version 2>/dev/null || echo unknown)",
  "source": "https://media.codeweavers.com/pub/crossover/source/crossover-sources-${CX_VERSION}.tar.gz",
  "patches": [$(cd "$ROOT/engine/patches" 2>/dev/null && ls *.patch 2>/dev/null | sed 's/.*/"&"/' | paste -sd, -)],
  "license": "Wine is LGPL-2.1-or-later. Corresponding source is attached to the same release."
}
JSON

  log "Packing"
  mkdir -p "$DIST"
  tar -C "$(dirname "$STAGE")" -cJf "$DIST/$NAME.tar.xz" "$NAME"
  ( cd "$DIST" && shasum -a 256 "$NAME.tar.xz" | tee "$NAME.tar.xz.sha256" )
  du -h "$DIST/$NAME.tar.xz"
}

smoke_test() {
  log "Smoke test"
  "$STAGE/bin/wine" --version
}

step="${1:-all}"
need_tools
case "$step" in
  download) download ;;
  build)    download; prepare_sources; build_deps; build_wine ;;
  resume)   compile_wine; package; smoke_test ;;
  package)  package; smoke_test ;;
  all)      download; prepare_sources; build_deps; build_wine; package; smoke_test ;;
  *) echo "usage: $0 [download|build|resume|package|all]" >&2; exit 2 ;;
esac
