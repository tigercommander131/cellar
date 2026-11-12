#!/usr/bin/env bash
# Packs profiles/ into cellar-profiles.tar.gz, fills in packs.json's checksums and
# uploads both to the "packs" release, which every Cellar reads on launch.
# Usage: scripts/publish-packs.sh [--dry-run]     (needs GH_TOKEN or gh auth)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${REPO:-tigercommander131/cellar}"
OUT="$ROOT/.work/packs-release"
rm -rf "$OUT"; mkdir -p "$OUT"

# Every Cellar downloads these, and one it can't read is ignored without a word: the game just loses its
# fixes. So a mistake stops here instead.
python3 - "$ROOT/profiles" <<'PY'
import json, pathlib, sys
allowed = {"graphics": {"d3dmetal", "dxmt", "wined3d"}, "preset": {"quality", "balanced", "battery"}}
kinds = {"appId": str, "title": str, "windowsVersion": str, "notes": str, "minRAMGB": int, "frameCap": int,
         "retina": bool, "metalHUD": bool, "writeSteamAppID": bool, "steamOverlay": bool,
         "steamArgs": list, "gameArgs": list, "registry": list, "env": dict, "dllOverrides": dict,
         "graphics": str, "preset": str}
errors = []
for f in sorted(pathlib.Path(sys.argv[1]).glob("*.json")):
    try:
        p = json.loads(f.read_text())
    except ValueError as e:
        errors.append(f"{f.name}: not valid JSON ({e})"); continue
    if not isinstance(p, dict):
        errors.append(f"{f.name}: must be an object"); continue
    if p.get("appId") != f.stem:
        errors.append(f"{f.name}: appId must be \"{f.stem}\", the file's name")
    for key, value in p.items():
        if key not in kinds:
            errors.append(f"{f.name}: unknown setting \"{key}\"")
        elif not isinstance(value, kinds[key]) or (kinds[key] is int and isinstance(value, bool)):
            errors.append(f"{f.name}: \"{key}\" has the wrong kind of value")
        elif key in allowed and value not in allowed[key]:
            errors.append(f"{f.name}: \"{key}\" must be one of {sorted(allowed[key])}")
        elif kinds[key] is list and key != "registry" and not all(isinstance(v, str) for v in value):
            errors.append(f"{f.name}: \"{key}\" must be a list of text")
        elif kinds[key] is dict and not all(isinstance(v, str) for v in value.values()):
            errors.append(f"{f.name}: \"{key}\" must map text to text")
if errors:
    sys.exit("Not publishing, the game fixes have mistakes:\n  " + "\n  ".join(errors))
PY

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
