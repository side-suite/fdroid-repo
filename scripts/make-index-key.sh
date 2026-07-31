#!/usr/bin/env bash
# Generate the SideSuite App Pack index signing key. Run this ONCE, ever.
#
#   ./scripts/make-index-key.sh
#
# This key is not the APK signing key. It signs the repo *index*, and its
# SHA-256 fingerprint is printed into every QR code and stored by every client
# that adds the pack. Consequences:
#
#   * Losing it strands every user who ever added the pack. They cannot be
#     migrated; they would have to remove the pack and re-add a new one.
#   * Rotating it has the same cost. There is no key rotation story in the
#     F-Droid client.
#
# So: generate it, back it up in two places, and never publish anything signed
# with it until the backup is confirmed.
#
# The password is written to a file outside the git repo rather than echoed, so
# it does not end up in a terminal scrollback or a transcript.
set -euo pipefail

cd "$(dirname "$0")/.."

KEYSTORE="sidesuite-repo.p12"
SECRETS_DIR="../sidesuite-secrets"
PW_FILE="$SECRETS_DIR/repo-index-key-password.txt"
ALIAS="sidesuite"

if [ -f "$KEYSTORE" ]; then
  echo "REFUSING: $KEYSTORE already exists." >&2
  echo "If you genuinely want a new key, move the old one aside deliberately." >&2
  exit 1
fi

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
umask 077

# 33 bytes of entropy. base64 so it survives copy/paste into a password manager
# and into GitHub's secret field without quoting problems.
openssl rand -base64 33 | tr -d '\n' > "$PW_FILE"

# -storepass:file / -keypass:file keep the password off the process command
# line, where `ps` would expose it. PKCS12 requires both to be identical.
keytool -genkeypair \
  -keystore "$KEYSTORE" -storetype PKCS12 \
  -alias "$ALIAS" -keyalg RSA -keysize 4096 \
  -validity 10000 \
  -dname "CN=SideSuite, OU=App Pack, O=SideSuite, C=FI" \
  -storepass:file "$PW_FILE" -keypass:file "$PW_FILE"

chmod 600 "$KEYSTORE"

FINGERPRINT=$(keytool -list -keystore "$KEYSTORE" -storepass:file "$PW_FILE" 2>/dev/null \
  | grep -i 'SHA-256' | sed 's/.*: //; s/://g' | tr '[:lower:]' '[:upper:]')

cat <<EOF

  Keystore   $(pwd)/$KEYSTORE   (gitignored)
  Password   $(cd "$SECRETS_DIR" && pwd)/$(basename "$PW_FILE")   (outside the repo)

  Fingerprint (SHA-256, this goes in every QR):

    $FINGERPRINT

Do these three things now, before publishing anything:

  1. Put the password in your password manager, then delete the file above.
  2. Back up $KEYSTORE somewhere offline. Not only on this Mac.
  3. Set the GitHub Actions secrets on the pack repo:

       base64 -i $KEYSTORE | pbcopy
       gh secret set SIDESUITE_REPO_KEYSTORE_B64   # paste
       gh secret set KEYSTOREPASS                  # paste the password
       gh secret set KEYPASS                       # the same password

Then record the fingerprint in SID-166 so the QR and README work can reference
one authoritative value.
EOF
