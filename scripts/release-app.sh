#!/usr/bin/env bash
# Builds Cellar.app (Release), zips it, signs the zip for Sparkle, writes appcast.xml and
# uploads everything to GitHub: release v<version> plus the rolling "appcast" release.
# Usage: scripts/release-app.sh <version> [build number]     (needs Xcode 27 and gh auth)
# Signing key: .work/keys/sparkle_private.key (or SPARKLE_KEY_FILE).
set -euo pipefail

VERSION="${1:?usage: scripts/release-app.sh <version> [build]}"
BUILD="${2:-$(date +%Y%m%d%H)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${REPO:-tigercommander131/cellar}"
KEY="${SPARKLE_KEY_FILE:-$ROOT/.work/keys/sparkle_private.key}"
OUT="$ROOT/.work/app-release"
DERIVED="$ROOT/.build/release-app"
rm -rf "$OUT"; mkdir -p "$OUT"

cd "$ROOT"
xcodegen generate >/dev/null
xcodebuild -project Cellar.xcodeproj -scheme Cellar -configuration Release -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
APP="$DERIVED/Build/Products/Release/Cellar.app"
codesign --force --deep -s - "$APP"
codesign --verify --strict "$APP"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/Cellar.zip"
SPARKLE_BIN="$(find "$DERIVED/SourcePackages/artifacts" -type d -path '*Sparkle/bin' | head -1)"
SIG=$("$SPARKLE_BIN/sign_update" --ed-key-file "$KEY" "$OUT/Cellar.zip")
SIZE=$(stat -f%z "$OUT/Cellar.zip")
DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
URL="https://github.com/$REPO/releases/download/v$VERSION/Cellar.zip"

cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Cellar</title>
    <item>
      <title>Cellar $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <link>https://github.com/$REPO/releases/tag/v$VERSION</link>
      <enclosure url="$URL" $SIG type="application/octet-stream" length="$SIZE"/>
    </item>
  </channel>
</rss>
XML
echo "Built Cellar $VERSION ($BUILD), $(du -h "$OUT/Cellar.zip" | cut -f1)"

[ "${3:-}" = "--no-upload" ] && exit 0
gh release create "v$VERSION" -R "$REPO" --title "Cellar $VERSION" --notes-file "$ROOT/docs/RELEASE-NOTES.md" "$OUT/Cellar.zip"
gh release view appcast -R "$REPO" >/dev/null 2>&1 || \
  gh release create appcast -R "$REPO" --title "Update feed" --notes "Sparkle update feed. Not a download." --latest=false
gh release upload appcast -R "$REPO" --clobber "$OUT/appcast.xml"
echo "Released v$VERSION."
