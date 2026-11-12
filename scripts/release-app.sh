#!/usr/bin/env bash
# Builds Cellar.app (Release), zips it, signs the zip for Sparkle, writes appcast.xml and
# uploads everything to GitHub: release v<version> plus the rolling "appcast" release.
# Usage: scripts/release-app.sh <version> [build number] [--no-upload]   (needs Xcode 27 and gh auth)
#        CHANNEL=beta scripts/release-app.sh ...   publishes to people who switched on beta updates only.
# Signing key: .work/keys/sparkle_private.key (or SPARKLE_KEY_FILE).
# Code signing: the certificate from scripts/make-signing-cert.sh, so permissions survive updates.
set -euo pipefail

# --no-upload counts wherever it's typed: read as the build number, it used to publish to everyone.
UPLOAD=1
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --no-upload) UPLOAD=0 ;;
    -*) echo "Unknown option $arg" >&2; exit 1 ;;
    *) ARGS+=("$arg") ;;
  esac
done
VERSION="${ARGS[0]:?usage: scripts/release-app.sh <version> [build] [--no-upload]}"
BUILD="${ARGS[1]:-$(date +%Y%m%d%H)}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || { echo "Version must look like 3.0.1, not '$VERSION'." >&2; exit 1; }
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "Build number must be a number, not '$BUILD'." >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${REPO:-tigercommander131/cellar}"
KEY="${SPARKLE_KEY_FILE:-$ROOT/.work/keys/sparkle_private.key}"
OUT="$ROOT/.work/app-release"
DERIVED="$ROOT/.build/release-app"
CHANNEL="${CHANNEL:-}"
SIGN_KC="$ROOT/.work/keys/cellar-signing.keychain-db"
[ -e "$SIGN_KC" ] || { echo "No signing certificate. Run scripts/make-signing-cert.sh once." >&2; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT"

cd "$ROOT"
xcodegen generate >/dev/null
xcodebuild -project Cellar.xcodeproj -scheme Cellar -configuration Release -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
APP="$DERIVED/Build/Products/Release/Cellar.app"
security unlock-keychain -p "$(cat "$ROOT/.work/keys/cellar-signing.pass")" "$SIGN_KC"
SIGN_ID="$(security find-identity -p codesigning "$SIGN_KC" | awk '/Cellar Self-Signed/ {print $2; exit}')"
# codesign only finds an untrusted certificate through the search list, so it's on there just for this.
OLD_KC="$(security list-keychains -d user | tr -d '"' | xargs)"
trap 'security list-keychains -d user -s $OLD_KC' EXIT
security list-keychains -d user -s $OLD_KC "$SIGN_KC"
codesign --force --deep --timestamp=none -s "$SIGN_ID" "$APP"
security list-keychains -d user -s $OLD_KC
trap - EXIT
codesign --verify --strict "$APP"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/Cellar.zip"
SPARKLE_BIN="$(find "$DERIVED/SourcePackages/artifacts" -type d -path '*Sparkle/bin' | head -1)"
SIG=$("$SPARKLE_BIN/sign_update" --ed-key-file "$KEY" "$OUT/Cellar.zip")
DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
URL="https://github.com/$REPO/releases/download/v$VERSION/Cellar.zip"

TAG=""; [ -n "$CHANNEL" ] && TAG="<sparkle:channel>$CHANNEL</sparkle:channel>"
ITEM="    <item>
      <title>Cellar $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      $TAG
      <link>https://github.com/$REPO/releases/tag/v$VERSION</link>
      <enclosure url=\"$URL\" $SIG type=\"application/octet-stream\"/>
    </item>"
# A beta sits beside the current stable version, which everyone else keeps getting.
# A stable release replaces the whole feed.
KEEP=""
if [ -n "$CHANNEL" ]; then
  KEEP="$(curl -fsSL "https://github.com/$REPO/releases/download/appcast/appcast.xml" | python3 -c '
import re, sys
for item in re.findall(r"    <item>.*?</item>", sys.stdin.read(), re.S):
    if "sparkle:channel" not in item: print(item)')"
fi
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Cellar</title>
$ITEM
$KEEP
  </channel>
</rss>
XML
echo "Built Cellar $VERSION ($BUILD), $(du -h "$OUT/Cellar.zip" | cut -f1)"

[ "$UPLOAD" = 1 ] || exit 0
if [ -n "$CHANNEL" ]; then
  gh release create "v$VERSION" -R "$REPO" --title "Cellar $VERSION ($CHANNEL)" --notes-file "$ROOT/docs/RELEASE-NOTES.md" --prerelease "$OUT/Cellar.zip"
else
  gh release create "v$VERSION" -R "$REPO" --title "Cellar $VERSION" --notes-file "$ROOT/docs/RELEASE-NOTES.md" --latest "$OUT/Cellar.zip"
fi
gh release view appcast -R "$REPO" >/dev/null 2>&1 || \
  gh release create appcast -R "$REPO" --title "Update feed" --notes "Sparkle update feed. Not a download." --latest=false
gh release upload appcast -R "$REPO" --clobber "$OUT/appcast.xml"
echo "Released v$VERSION."
