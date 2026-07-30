#!/usr/bin/env bash
# Fetch the latest release APK for each app in apps.json into repo/.
#
# Stateless by design: repo/ is rebuilt from GitHub Releases on every run and is
# never committed. GitHub Releases stay the single source of truth, so the pack
# is always reconstructible from scratch and the git history never accumulates
# APK blobs.
#
# Apps with no release yet (e.g. SideHome) are skipped with a notice, not an
# error — they join the pack automatically once they ship.
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p repo staging
rm -rf staging
mkdir -p staging

skipped=""

while read -r name package gh_repo; do
  echo "==> $name  ($gh_repo)"
  dest="staging/$package"
  mkdir -p "$dest"

  if ! tag=$(gh release view -R "$gh_repo" --json tagName -q .tagName 2>/dev/null); then
    echo "    no release yet, or repo not found — skipping"
    skipped="$skipped $name"
    continue
  fi

  if ! gh release download "$tag" -R "$gh_repo" -p '*.apk' -D "$dest" --clobber 2>/dev/null; then
    echo "    release $tag has no .apk asset — skipping"
    skipped="$skipped $name"
    continue
  fi

  count=$(find "$dest" -name '*.apk' | wc -l | tr -d ' ')
  if [ "$count" -ne 1 ]; then
    echo "    ERROR: expected exactly 1 APK in $gh_repo $tag, found $count:" >&2
    find "$dest" -name '*.apk' >&2
    echo "    Refusing to guess which one to publish. If split/ABI APKs are now" >&2
    echo "    a thing, teach this script how to name them." >&2
    exit 1
  fi

  apk=$(find "$dest" -name '*.apk')
  mv "$apk" "repo/${name}-${tag}.apk"
  echo "    -> repo/${name}-${tag}.apk"
done < <(jq -r '.[] | "\(.name) \(.package) \(.repo)"' apps.json)

rm -rf staging

echo
echo "APKs staged in repo/:"
ls -la repo/*.apk 2>/dev/null || echo "  (none)"

if [ -n "$skipped" ]; then
  echo
  echo "NOT IN THIS BUILD (no release yet):$skipped"
fi
