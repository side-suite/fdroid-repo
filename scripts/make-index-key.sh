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

Do these in order, before publishing anything. KEEP THE PASSWORD FILE UNTIL
STEP 3 IS DONE — the secret-setting commands read from it.

  1. Copy the password into your password manager now. Do not delete the file
     yet; deleting it before step 3 leaves you retyping a 44-character random
     string, and a keystore whose password is lost is a keystore you must
     regenerate.
  2. Back up $KEYSTORE somewhere offline. Not only on this Mac.
  3. Once side-suite/fdroid-repo exists on GitHub, set its three Actions
     secrets. These are REPOSITORY secrets, not account-wide ones. The -R flag
     is required here because this repo has no git remote for gh to infer from,
     and the values are piped in so they never touch the clipboard:

       base64 -i $KEYSTORE | tr -d '\\n' \\
         | gh secret set SIDESUITE_REPO_KEYSTORE_B64 -R side-suite/fdroid-repo
       gh secret set KEYSTOREPASS -R side-suite/fdroid-repo < $PW_FILE
       gh secret set KEYPASS      -R side-suite/fdroid-repo < $PW_FILE

     Check them with:  gh secret list -R side-suite/fdroid-repo

  4. Only now delete $PW_FILE, having confirmed the password manager entry
     opens and the three secrets are listed.

Then record the fingerprint in SID-166 so the QR and README work can reference
one authoritative value.

If the password is ever lost BEFORE the pack is published, the fix is free:
delete $KEYSTORE and run this script again. After publishing it is not fixable
at all, because the fingerprint is pinned in every client that added the pack.
EOF
