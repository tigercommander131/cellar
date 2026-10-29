#!/usr/bin/env bash
# Packs profiles/ into cellar-profiles.tar.gz, fills in packs.json's checksums and
# uploads both to the "packs" release, which every Cellar reads on launch.
# Usage: scripts/publish-packs.sh [--dry-run]     (needs GH_TOKEN or gh auth)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${REPO:-tigercommander131/cellar}"
OUT="$ROOT/.work/packs-release"
rm -rf "$OUT"; mkdir -p "$OUT"

# Deterministic tarball (fixed owners and times, sorted, no gzip timestamp) so unchanged
# profiles keep the same checksum on any machine.
python3 - "$ROOT" "$OUT/cellar-profiles.tar.gz" <<'PY'
import gzip, io, pathlib, sys, tarfile
root, out = pathlib.Path(sys.argv[1]), sys.argv[2]
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.USTAR_FORMAT) as tar:
    for f in sorted((root / "profiles").glob("*.json")):
        data = f.read_bytes()
        info = tarfile.TarInfo(f"profiles/{f.name}")
        info.size, info.mode, info.mtime = len(data), 0o644, 0
        tar.addfile(info, io.BytesIO(data))
with open(out, "wb") as raw, gzip.GzipFile(fileobj=raw, mode="wb", mtime=0, filename="") as gz:
    gz.write(buf.getvalue())
PY
PROFILES_SHA=$(shasum -a 256 "$OUT/cellar-profiles.tar.gz" | cut -d' ' -f1)

ENGINE_URL=$(python3 -c "import json;print([p['url'] for p in json.load(open('$ROOT/packs.json'))['packs'] if p['kind']=='engine'][0])")
ENGINE_SHA=$(curl -fsSL "$ENGINE_URL.sha256" | cut -d' ' -f1)
[ ${#ENGINE_SHA} -eq 64 ] || { echo "Couldn't read the engine checksum at $ENGINE_URL.sha256" >&2; exit 1; }

python3 - "$ROOT/packs.json" "$OUT/packs.json" "$ENGINE_SHA" "$PROFILES_SHA" <<'PY'
import json, sys
src, dst, engine, profiles = sys.argv[1:]
m = json.load(open(src))
for p in m["packs"]:
    if p["kind"] == "engine": p["sha256"] = engine
    if p["kind"] == "profiles":
        p["sha256"] = profiles
        p["version"] = profiles[:12]
json.dump(m, open(dst, "w"), indent=2)
PY
cat "$OUT/packs.json"

[ "${1:-}" = "--dry-run" ] && exit 0
gh release view packs -R "$REPO" >/dev/null 2>&1 || \
  gh release create packs -R "$REPO" --title "Packs manifest" --notes "packs.json and game fixes read by every Cellar. Updated automatically." --latest=false
gh release upload packs -R "$REPO" --clobber "$OUT/packs.json" "$OUT/cellar-profiles.tar.gz"
echo "Published packs.json and game fixes."
