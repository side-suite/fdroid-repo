# SideSuite App Pack

An **F-Droid repository** carrying [SideType](https://github.com/side-suite/SideType),
[SideCall](https://github.com/side-suite/SideCall) and SideHome for the
[Sidephone SP-01](https://sidephone.com).

The SP-01's stock **Library** app is upstream F-Droid Basic (`org.fdroid.basic`)
with "repository" renamed to "app pack". So an App Pack *is* an F-Droid repo, and
one QR code installs the whole suite — with **no unknown-sources prompt and
automatic updates**, because the Library is a privileged system installer.

> Not affiliated with Sidephone. Every app is also published as a signed APK on
> GitHub Releases for Obtainium or manual install; that path is supported
> permanently and is not a fallback.

**Address:** `https://fdroid.sidesuite.app/fdroid/repo`
**Fingerprint:** _(fill in from the real key — see “The key” below)_

---

## How it works

Three layers, deliberately separate:

| Layer | What | Where |
|---|---|---|
| **Source of truth** | Signed release APKs | GitHub Releases, in each app's own repo |
| **Derivation** | `fdroid update` over the fetched APKs | this repo's CI |
| **Serving** | Static files | GitHub Pages, behind a custom domain |

The build is **stateless**. `repo/` is rebuilt from GitHub Releases on every run
and is `.gitignore`d — no APKs ever enter git history. The pack must always be
reconstructible from scratch by re-running the workflow. This is the discipline
that stopped `xarantolus/fdroid`, which committed APKs and grew unboundedly
before dying in 2022.

Adding an app is one entry in [`apps.json`](apps.json) plus a
`metadata/<package>.yml`. Apps with no release yet are skipped with a notice, so
SideHome joins automatically the day it ships.

### Why this address, on this host

`repo_url` is baked into the signed index, stored by every client that adds the
pack, and printed into **every QR code ever published**. Changing the *host*
later is free. Changing the *address* strands every printed QR and every
installed client.

So the address is a custom domain from day one, and the host is whatever is
cheapest behind it:

- **GitHub Pages** — no per-file size cap, zero infrastructure, no egress bill.
  (Cloudflare Pages is ruled out: its 25 MiB per-asset limit is smaller than
  SideType's 41 MiB APK.)
- **Cloudflare R2 is the escape hatch**, not a day-one decision. If bandwidth
  ever becomes a real problem, swap DNS and mirror the bytes — clients and
  printed QRs never notice. Worth knowing that GitHub's fair-use terms discourage
  Pages as a file-hosting service; the portable address means being flagged costs
  a DNS record, not a re-scan.

A repo **cannot** delegate APK hosting to GitHub Releases.
`PackageVersionV2.file` has no absolute-URL field, the client concatenates
repo-relative paths, and it does not follow redirects. The repo must serve the
bytes itself.

---

---

# Maintaining the pack

Everything below is for whoever runs this repo. If you came here to install the
apps, you already have what you need above.

---

## The key

Two different keys, and conflating them is the one unrecoverable mistake here.

- **APK signing keys** stay exactly where they are, in each app repo. Android
  requires the same key to update an installed app, so they must never enter CI.
- **The repo index key** is separate, generated once, and lives in CI.

The index key's SHA-256 fingerprint is pinned into every QR code you publish.
**Lose it and the pack is dead** — clients reject a differently-signed index and
every user must delete and re-add the pack. Back it up offline *and* in a
password manager before the first publish.

Generate it once, with:

```sh
./scripts/make-index-key.sh
```

That writes the keystore here (gitignored) and the password to a file *outside*
the repo, rather than echoing it into a terminal scrollback. It refuses to run
if a keystore already exists. Follow the three steps it prints before publishing
anything.

Never use `fdroid update --create-key` in CI — it generates a random password
and writes it back into `config.yml`.

Publish the fingerprint in the QR and as text on the site. Sidephone's own eight
packs ship unpinned (trust-on-first-use); pinning costs nothing and is the
difference between a user trusting DNS and a user trusting your key.

---

## Required secrets

GitHub Actions secrets live at one of several **scopes**. Nothing here is
account-wide. Two scopes are in play across SideSuite, and mixing them up is the
usual source of "why can't the workflow see it":

| Scope | Set with | Used for |
|---|---|---|
| **Repository** | `gh secret set NAME -R side-suite/fdroid-repo` | everything in the table below |
| **Organisation** | `gh secret set NAME --org side-suite --visibility all` | only `FDROID_DISPATCH_TOKEN`, so all three app repos share one copy |

`gh secret set` defaults to the repository inferred from the current directory's
git remote. **This repo has no remote**, so `-R` is not optional here — without
it the command has nothing to infer from.

These four are repository secrets on `side-suite/fdroid-repo`:

| Secret | What |
|---|---|
| `SIDESUITE_REPO_KEYSTORE_B64` | `base64 -i sidesuite-repo.p12 \| tr -d '\n'` |
| `KEYSTOREPASS` | keystore password |
| `KEYPASS` | key password (identical — PKCS12 requires it) |
| `APPS_READ_TOKEN` | *optional*, only if an app repo goes private |

Pipe values in rather than pasting; secrets are write-only once set, so a typo
is invisible until a run fails:

```sh
base64 -i sidesuite-repo.p12 | tr -d '\n' \
  | gh secret set SIDESUITE_REPO_KEYSTORE_B64 -R side-suite/fdroid-repo
gh secret set KEYSTOREPASS -R side-suite/fdroid-repo < ../sidesuite-secrets/repo-index-key-password.txt
gh secret set KEYPASS      -R side-suite/fdroid-repo < ../sidesuite-secrets/repo-index-key-password.txt

gh secret list -R side-suite/fdroid-repo
```

GitHub Pages must be enabled with **source: GitHub Actions**, and
`fdroid.sidesuite.app` set as the custom domain.

### Switching to Cloudflare R2

The R2 variant is written and waiting in `.github/workflows-variants/publish-r2.yml`.
GitHub only reads `.github/workflows/` and does not recurse, so it is inert
where it sits and cannot double-publish. To switch:

```sh
git mv .github/workflows/publish.yml             .github/workflows-variants/publish-pages.yml
git mv .github/workflows-variants/publish-r2.yml .github/workflows/publish.yml
```

…then point `fdroid.sidesuite.app` at the bucket and add `R2_ACCOUNT_ID`,
`R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `CF_ZONE_ID`, `CF_CACHE_PURGE_TOKEN`.
`config.yml` does not change — that is the point of owning the address.

The R2 tail is not a straight port; three failure modes are specific to it and
are handled explicitly in that file: Cloudflare caches 404s (so APKs upload
before the index), `aws s3 sync --delete` treats `--exclude`d files as deleted
(so pruning happens in a separate, exclude-free pass *after* the index is live),
and the index filenames are stable across versions (so they get `no-cache` plus
an edge purge).

---

## Building locally

Requires `fdroidserver`, a JDK, `apksigner` via `ANDROID_HOME`, plus
authenticated `gh` and `jq`. On macOS: `brew install fdroidserver`.

```sh
export KEYSTOREPASS=... KEYPASS=...
./scripts/build.sh
```

## Testing on a real SP-01 — no publishing needed

You do **not** need a public host to test a pack. The Library's
`networkSecurityConfig` sets `base-config cleartextTrafficPermitted="true"`, so
the phone can fetch over plain HTTP from your machine through the USB cable:

```sh
./scripts/test-on-device.sh
```

This does `adb reverse tcp:8777`, serves `repo/` locally, and opens the
Library's "Add app pack" screen pointed at it. Verified working end-to-end on
`SP01GE260600728`, 2026-07-30.

Two things that will confuse you:

- After tapping **Add app pack**, the client opens the app list with the repo
  name pre-filled in the **search field**, showing *"No matching applications
  available."* This is not a failure. Clear the field, or open an app directly
  with `am start ... AppDetailsActivity -e appid <package>`.
- **Every** app renders a placeholder icon in the Library, including Sidephone's
  own packs. Device-wide behaviour — don't go hunting for a bug in the index.

To prove silent install, uninstall a **low-stakes** app first and reinstall from
the pack — never the active IME. Success is
`installerPackageName=org.fdroid.basic` with no unknown-sources prompt.
Uninstalling resets runtime permissions and wipes app data.

Remove the test pack afterwards via **Library → Settings → App Packs**;
`ManageReposActivity` is not externally launchable, so this is a manual step.

---

## Triggering a rebuild from an app release

**None of the three app repos has any CI.** Releases are cut by hand, so there
is no existing release workflow to hook into — each repo gets a small standalone
workflow of its own instead:

    .github/workflows/notify-app-pack.yml

It triggers on `release: [published]`, so it fires however the release was made
(web UI, `gh release create`, API), and `POST`s `{"event_type":"app-released"}`
to this repo's `dispatches` endpoint. See that file in any of the app repos for
the full version; the shape is:

```yaml
on:
  release:
    types: [published]
```

To fire, the workflow must live on the app repo's **default branch** —
`master` for SideType, `main` for SideCall.

### The token

`GITHUB_TOKEN` **cannot dispatch across repositories.** It needs a fine-grained
PAT with `contents: write` on `side-suite/fdroid-repo` and nothing else, stored
as an **organisation secret** named `FDROID_DISPATCH_TOKEN` on `side-suite`, so
one copy serves all three repos.

If it is missing the notify job fails loudly — a red X on the app repo — but the
release itself is unaffected. `workflow_dispatch` here, or the weekly cron, will
pick the release up regardless. The dispatch only buys immediacy.

---

## Gotchas, all confirmed

- An APK with **no `metadata/<pkg>.yml` is silently excluded** from the index —
  warning only. The workflow fails on an empty index to catch this.
- Secrets syntax is `{env: VAR}`, not `${VAR}`. But `keystore: {env: ...}` is
  **broken** ([fdroidserver#870](https://gitlab.com/fdroid/fdroidserver/-/issues/870)) —
  it stays a literal path, written from the base64 secret at runtime.
- `FDROID_KEY_STORE_PASS` / `FDROID_KEY_PASS` are internal to fdroidserver and
  are **not** read from your environment.
- `repo_icon` resolves relative to `repo/icons/`, so `icon.png` is copied there
  before `fdroid update` runs.
- fastlane metadata uses **`summary.txt`** and **`description.txt`** here, not
  upstream fastlane's `short_description.txt` / `full_description.txt`.
- The old F-Droid docs page still shows Python-style `repo_url = "..."`;
  `config.py` was removed in 2.4.0. Use YAML.

Full research and on-device evidence:
`SideSuite/research/app-library-qr.md` (§9 is the verification run).
