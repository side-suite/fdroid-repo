#!/usr/bin/env bash
# Fetch the most recent KEEP_RELEASES release APKs for each app in apps.json
# into repo/.
#
# Stateless by design: repo/ is rebuilt from GitHub Releases on every run and is
# never committed. GitHub Releases stay the single source of truth, so the pack
# is always reconstructible from scratch and the git history never accumulates
# APK blobs.
#
# Why more than one release per app: F-Droid clients download an APK by the
# exact filename recorded in the index they last synced. A client that has not
# refreshed since the previous publish still asks for the OLD filename. When the
# pack only ever held the newest APK, that request 404'd and the client reported
# a bare `ClientRequestException` — which is exactly what happened to SideHome
# users after v1.1 was replaced by v1.2 on 2026-08-03. Keeping the last few
# APKs live means every filename a client could plausibly still be holding keeps
# resolving, so a stale client downloads successfully and picks up the new
# version on its next sync. Costs a few MB of static hosting.
#
# archive_older: 0 in config.yml keeps all of these in the main index rather
# than shunting the older ones into an archive repo clients do not subscribe to.
#
# Apps with no release yet are skipped with a notice, not an error — they join
# the pack automatically once they ship.
set -euo pipefail

cd "$(dirname "$0")/.."

# How many releases back to keep downloadable per app. Anything >= 2 fixes the
# stale-client 404; 3 leaves room for two publishes in one day (which is how the
# original bug was hit) without a client ever falling off the end.
KEEP_RELEASES="${KEEP_RELEASES:-3}"

mkdir -p repo staging
rm -rf staging
mkdir -p staging

# Drop APKs from previous local runs so a local build matches a fresh CI one.
# CI always starts from an empty checkout; without this, a laptop accumulates
# old versions and silently publishes an index CI would never produce.
rm -f repo/*.apk

skipped=""

while read -r name package gh_repo; do
  echo "==> $name  ($gh_repo)"

  # `gh api` rather than `gh release list --json`: the --json flag on
  # `release list` only exists in gh >= 2.36, and CI runners and laptops do not
  # agree on the gh version. The REST endpoint returns newest first.
  if ! releases=$(gh api "repos/$gh_repo/releases?per_page=30" \
        --jq '.[] | select(.draft == false and .prerelease == false) | .tag_name' \
        2>/dev/null </dev/null); then
    echo "    repo not found, or releases unreadable — skipping"
    skipped="$skipped $name"
    continue
  fi

  tags=$(printf '%s\n' "$releases" | grep -v '^$' | head -n "$KEEP_RELEASES" || true)
  if [ -z "$tags" ]; then
    echo "    no release yet — skipping"
    skipped="$skipped $name"
    continue
  fi

  got=0
  n=0
  while read -r tag; do
    [ -n "$tag" ] || continue
    n=$((n + 1))
    # The newest release is the one being published; an older one is only here
    # to keep stale clients working. So a problem with the newest is loud, and a
    # problem with an older one is a note.
    newest=$([ "$n" -eq 1 ] && echo yes || echo no)

    dest="staging/$package/$tag"
    mkdir -p "$dest"

    if ! gh release download "$tag" -R "$gh_repo" -p '*.apk' -D "$dest" --clobber \
          2>/dev/null </dev/null; then
      echo "    $tag: no .apk asset — skipping"
      continue
    fi

    count=$(find "$dest" -name '*.apk' | wc -l | tr -d ' ')
    if [ "$count" -ne 1 ]; then
      if [ "$newest" = yes ]; then
        echo "    ERROR: expected exactly 1 APK in $gh_repo $tag, found $count:" >&2
        find "$dest" -name '*.apk' >&2
        echo "    Refusing to guess which one to publish. If split/ABI APKs are now" >&2
        echo "    a thing, teach this script how to name them." >&2
        exit 1
      fi
      echo "    $tag: found $count APKs, not 1 — skipping this older version"
      continue
    fi

    apk=$(find "$dest" -name '*.apk')
    # This filename is a contract: it is what lands in the index and what every
    # client that synced during this version's lifetime will ask for later.
    mv "$apk" "repo/${name}-${tag}.apk"
    echo "    -> repo/${name}-${tag}.apk$([ "$newest" = yes ] && echo '  (current)' || echo '  (kept for stale clients)')"
    got=$((got + 1))
  done <<EOF
$tags
EOF

  if [ "$got" -eq 0 ]; then
    echo "    no usable APK in the last $KEEP_RELEASES releases — skipping"
    skipped="$skipped $name"
  fi
done < <(jq -r '.[] | "\(.name) \(.package) \(.repo)"' apps.json)

rm -rf staging

echo
echo "APKs staged in repo/:"
ls -la repo/*.apk 2>/dev/null || echo "  (none)"

if [ -n "$skipped" ]; then
  echo
  echo "NOT IN THIS BUILD (no release yet):$skipped"
fi
