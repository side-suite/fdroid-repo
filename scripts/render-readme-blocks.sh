#!/usr/bin/env bash
# Fill the real fingerprint into the README install blocks and distribute the QR
# image to the three app repos.
#
#   ./scripts/render-readme-blocks.sh [path/to/sidesuite-secrets/repo-index-key-password.txt]
#
# Reads the fingerprint from the built index rather than the keystore, so what
# lands in the READMEs is provably what the pack actually publishes. A README
# whose fingerprint does not match the live index is worse than no fingerprint —
# it trains people to click through a mismatch warning.
#
# Run ./scripts/build.sh first.
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="../SideSuite/launch/readme-install-blocks.md"
OUT="../SideSuite/launch/readme-install-blocks.rendered.md"
QR="repo/index.png"

if [ ! -f repo/index-v2.json ]; then
  echo "ERROR: repo/index-v2.json not found — run ./scripts/build.sh first." >&2
  exit 1
fi

# The fingerprint a client pins is the SHA-256 of the DER signing certificate,
# uppercase hex. fdroidserver exposes that certificate in more than one place and
# the exact field has moved between index versions, so try each known location
# and fail loudly rather than emit a fingerprint that might be wrong.
FINGERPRINT=$(python3 - <<'PY'
import hashlib, json, sys, xml.etree.ElementTree as ET
from pathlib import Path

def fp(cert_hex):
    return hashlib.sha256(bytes.fromhex(cert_hex)).hexdigest().upper()

candidates = []

# index-v1.json carries the DER cert as repo.pubkey.
p = Path("repo/index-v1.json")
if p.exists():
    repo = json.loads(p.read_text()).get("repo", {})
    if repo.get("pubkey"):
        candidates.append(("index-v1.json", fp(repo["pubkey"])))

# index.xml (v0) carries the same value as a <repo pubkey="..."> attribute.
# Note <repo> is a CHILD of the <fdroid> root, not the root itself.
p = Path("repo/index.xml")
if p.exists():
    node = ET.parse(p).getroot().find("repo")
    pubkey = node.get("pubkey") if node is not None else None
    if pubkey:
        candidates.append(("index.xml", fp(pubkey)))

# index-v2.json, in case a future fdroidserver puts it on the repo object.
p = Path("repo/index-v2.json")
if p.exists():
    repo = json.loads(p.read_text()).get("repo", {})
    cert = repo.get("signingCert") or repo.get("cert") or repo.get("pubkey")
    if cert:
        candidates.append(("index-v2.json", fp(cert)))

if not candidates:
    sys.exit("ERROR: could not find the signing certificate in any index file.\n"
             "       Read repo/index-v1.json and look for the field holding the\n"
             "       hex-encoded certificate, then teach this script about it.\n"
             "       Do NOT paste a fingerprint from anywhere else.")

values = {f for _, f in candidates}
if len(values) > 1:
    sys.exit("ERROR: index files disagree on the fingerprint:\n  "
             + "\n  ".join(f"{src}: {f}" for src, f in candidates))

print(candidates[0][1])
PY
)

echo "fingerprint: $FINGERPRINT"

# Cross-check against the keystore when the password file is available, because
# agreement between two independent sources is the whole point of publishing a
# fingerprint at all.
PW_FILE="${1:-../sidesuite-secrets/repo-index-key-password.txt}"
if [ -f "$PW_FILE" ] && [ -f sidesuite-repo.p12 ]; then
  FROM_KEYSTORE=$(keytool -list -keystore sidesuite-repo.p12 -storepass:file "$PW_FILE" 2>/dev/null \
    | grep -i 'SHA-256' | sed 's/.*: //; s/://g' | tr '[:lower:]' '[:upper:]')
  if [ "$FROM_KEYSTORE" != "$FINGERPRINT" ]; then
    echo "::error::Index fingerprint does not match the keystore." >&2
    echo "  index:    $FINGERPRINT" >&2
    echo "  keystore: $FROM_KEYSTORE" >&2
    exit 1
  fi
  echo "cross-checked against the keystore: match"
else
  echo "note: keystore password file not found, skipping cross-check ($PW_FILE)"
fi

sed "s|__FINGERPRINT__|$FINGERPRINT|g" "$SRC" > "$OUT"
echo "wrote $OUT"

# fdroid writes repo/index.png — a QR of the address plus fingerprint. Use it
# rather than generating one by hand; hand-made QRs are how a wrong fingerprint
# gets published.
declare -a TARGETS=(
  "../tt9/docs/brand/app-pack-qr.png"
  "../sidecall/assets/app-pack-qr.png"
  "../sidehome/assets/app-pack-qr.png"
)

if [ -f "$QR" ]; then
  for t in "${TARGETS[@]}"; do
    if [ -d "$(dirname "$t")" ]; then
      cp "$QR" "$t"
      echo "QR -> $t"
    else
      echo "skipped $t (directory does not exist)"
    fi
  done
else
  echo "WARNING: $QR not found; no QR distributed." >&2
fi

cat <<EOF

Next:
  1. Read $OUT and paste each block into its README.
  2. Add the QR images to git in each app repo.
  3. After publishing, confirm the live index agrees:
       curl -s https://fdroid.sidesuite.app/fdroid/repo/index-v2.json | head -c 200
EOF
