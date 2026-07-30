#!/usr/bin/env bash
# Serve the built repo to a USB-connected SP-01 and open the "Add app pack"
# screen. No publishing, no domain, no GitHub — the phone reaches the Mac
# through the adb reverse tunnel.
#
# This works because the Library's networkSecurityConfig has
# `base-config cleartextTrafficPermitted="true"`, so plain HTTP to an arbitrary
# host is allowed. Verified end-to-end 2026-07-30.
#
#   ./scripts/test-on-device.sh [serial]
#
# Ctrl-C to stop the server. Afterwards, remove the test pack on the device via
# Library -> Settings -> App Packs, or it will keep retrying a dead address.
set -euo pipefail

cd "$(dirname "$0")/.."

PORT=8777
SERIAL="${1:-$(adb devices | awk 'NR==2{print $1}')}"

if [ -z "$SERIAL" ]; then
  echo "ERROR: no adb device found." >&2
  exit 1
fi

if [ ! -f repo/index-v2.json ]; then
  echo "ERROR: repo/index-v2.json not found — run ./scripts/build.sh first." >&2
  exit 1
fi

# The index's own address must match what the device will request, so rebuild
# a throwaway index pointed at the tunnel if needed. Here we just serve what
# was built; if repo_url is the production domain the device will still fetch
# over the tunnel but the client stores the production address.
ADDRESS=$(python3 -c "import json;print(json.load(open('repo/index-v2.json'))['repo']['address'])")
echo "index address: $ADDRESS"

# The fingerprint is the SHA-256 of the index signing certificate, hex.
# fdroid bakes it into repo/index.png's QR; read it off the keystore directly.
FP=$(keytool -list -keystore sidesuite-repo.p12 -storepass "${KEYSTOREPASS:?set KEYSTOREPASS}" 2>/dev/null \
      | grep -i 'SHA-256' | sed 's/.*: //; s/://g' | tr '[:lower:]' '[:upper:]')
echo "fingerprint:   $FP"

mkdir -p www/fdroid
ln -sfn ../../repo www/fdroid/repo

adb -s "$SERIAL" reverse "tcp:$PORT" "tcp:$PORT"
trap 'adb -s "$SERIAL" reverse --remove tcp:'"$PORT"' 2>/dev/null || true' EXIT

( cd www && python3 -m http.server "$PORT" --bind 0.0.0.0 ) &
SRV=$!
trap 'kill $SRV 2>/dev/null; adb -s "$SERIAL" reverse --remove tcp:'"$PORT"' 2>/dev/null || true' EXIT
sleep 2

adb -s "$SERIAL" shell am force-stop org.fdroid.basic
adb -s "$SERIAL" shell am start \
  -n org.fdroid.basic/org.fdroid.fdroid.views.repos.AddRepoActivity \
  -a android.intent.action.VIEW \
  -d "fdroidrepo://127.0.0.1:$PORT/fdroid/repo?fingerprint=$FP"

cat <<'EOF'

Serving. On the device you should see "Add app pack" listing the apps.

Notes from the 2026-07-30 run:
  * After tapping "Add app pack", the client opens the app list with the repo
    name pre-filled in the SEARCH FIELD, showing "No matching applications
    available." That is NOT a failure. Clear the field.
  * To check a specific app directly:
      adb shell am start -n org.fdroid.basic/org.fdroid.fdroid.views.AppDetailsActivity \
        -e appid fi.palonkorpi.sidetype
  * To prove silent install, uninstall a LOW-STAKES app first (never the active
    IME) and install it from the pack. Success looks like:
      installerPackageName=org.fdroid.basic  and no unknown-sources prompt.
    Uninstalling resets runtime permissions and wipes app data.

Ctrl-C to stop.
EOF

wait $SRV
