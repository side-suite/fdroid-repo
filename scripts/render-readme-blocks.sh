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
# uppercase hex.
#
# It is NOT in any of the index JSON files. Verified against the live pack on
# 2026-07-31: index-v1.json's repo object holds only address/description/icon/
# name/timestamp/version, and index-v2.json's only adds categories. The
# certificate lives in the JAR signature block of entry.jar
# (META-INF/<alias>.RSA), which is what the client actually verifies anyway.
FINGERPRINT=$(keytool -printcert -jarfile repo/entry.jar 2>/dev/null \
  | grep -i 'SHA256:' | head -1 | sed 's/.*SHA256: *//; s/://g' | tr -d '[:space:]' \
  | tr '[:lower:]' '[:upper:]')

if [ ${#FINGERPRINT} -ne 64 ]; then
  echo "::error::Could not read a 64-char SHA-256 from repo/entry.jar (got '${FINGERPRINT}')." >&2
  echo "         Do NOT paste a fingerprint from anywhere else — derive it from the" >&2
  echo "         signed index, or the README will disagree with what clients see." >&2
  exit 1
fi

# Second, independent derivation. Agreement between two code paths is the whole
# reason for publishing a fingerprint, so the generator should hold itself to it.
VIA_OPENSSL=$(unzip -p repo/entry.jar 'META-INF/*.RSA' 2>/dev/null \
  | openssl pkcs7 -inform DER -print_certs 2>/dev/null \
  | openssl x509 -outform DER 2>/dev/null \
  | shasum -a 256 | awk '{print toupper($1)}')

if [ -n "$VIA_OPENSSL" ] && [ "$VIA_OPENSSL" != "$FINGERPRINT" ]; then
  echo "::error::keytool and openssl disagree on the fingerprint:" >&2
  echo "  keytool: $FINGERPRINT" >&2
  echo "  openssl: $VIA_OPENSSL" >&2
  exit 1
fi

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
