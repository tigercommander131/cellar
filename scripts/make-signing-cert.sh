#!/usr/bin/env bash
# Makes the self-signed certificate Cellar is signed with, once. macOS ties permissions like Screen
# Recording to the signature, and an ad-hoc signature changes with every build, so a certificate that
# stays the same should keep them across updates. It lives in its own keychain in .work/keys (gitignored),
# so your login keychain and password aren't involved. Losing it only means macOS asks once more.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEYS="$ROOT/.work/keys"
KC="$KEYS/cellar-signing.keychain-db"
[ -e "$KC" ] && { echo "Already made: $KC"; exit 0; }
mkdir -p "$KEYS"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS="$(openssl rand -hex 24)"

cat > "$TMP/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Cellar Self-Signed
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF
openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$TMP/cert.conf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
LEGACY=""; openssl pkcs12 -help 2>&1 | grep -q -- '-legacy' && LEGACY="-legacy"
openssl pkcs12 -export $LEGACY -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/cert.p12" -passout "pass:$PASS"

security create-keychain -p "$PASS" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$PASS" "$KC"
security import "$TMP/cert.p12" -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null
umask 077; printf '%s' "$PASS" > "$KEYS/cellar-signing.pass"
echo "Made $KC"
