#!/usr/bin/env bash
# Build the signed F-Droid index. Identical logic to CI, so a green local run
# means a green CI run.
#
#   KEYSTOREPASS=... KEYPASS=... ./scripts/build.sh
#
# Requires: fdroidserver, a JDK, apksigner from Android build-tools (via
# ANDROID_HOME), gh (authenticated), jq.
set -euo pipefail

cd "$(dirname "$0")/.."

: "${KEYSTOREPASS:?set KEYSTOREPASS}"
: "${KEYPASS:?set KEYPASS}"
export KEYSTOREPASS KEYPASS

if [ ! -f sidesuite-repo.p12 ]; then
  echo "ERROR: sidesuite-repo.p12 not found." >&2
  echo "The repo index keystore is never committed. Restore it from backup," >&2
  echo "or see README.md if you are generating it for the first time." >&2
  exit 1
fi

# fdroidserver resolves repo_icon relative to repo/icons/, so the source icon
# has to be placed there before `fdroid update` runs.
mkdir -p repo/icons
cp icon.png repo/icons/icon.png

./scripts/fetch-apks.sh

echo
echo "==> fdroid update"
fdroid update -c --pretty --use-date-from-apk

echo
echo "==> index fingerprint"
fdroid update --version >/dev/null 2>&1 || true
keytool -list -keystore sidesuite-repo.p12 -storepass "$KEYSTOREPASS" 2>/dev/null \
  | grep -i 'SHA-256' \
  | sed 's/.*: //; s/://g' \
  | tr '[:lower:]' '[:upper:]'
