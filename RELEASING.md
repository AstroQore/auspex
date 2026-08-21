# Releasing Auspex

Every release is built from a tag by CI, lands as a **draft** GitHub Release,
and reaches people only when a maintainer reads that draft and publishes it.
Publishing is also what rebuilds the update feed installed copies read. Two
gates, on purpose: an update replaces software already running on somebody's
Mac.

There are two channels and one feed:

| Channel | Tag | Who sees it |
| --- | --- | --- |
| **Stable** | `v0.2.0` | everybody |
| **Dev** | `v0.2.0-dev.31` | people who chose Dev in Settings → Updates — **and** every stable release |

Dev users still receive stable releases because Sparkle always considers its
untagged default items. That asymmetry is what makes previews safe to offer: a
security fix cut on stable reaches the preview builds without anything special
being done for them.

> **The feed URL resolves now, and serves nothing yet.** New builds read
> `https://raw.githubusercontent.com/AstroQore/auspex/updates/appcast.xml`.
> `AstroQore/auspex` used to be private, which meant `raw.githubusercontent.com`
> would 404 for every user without a token; the repository is public now, so
> that blocker is gone and no mirror is needed. What is still missing is the
> `updates` branch itself — nothing has been published to it, so the URL 404s
> because the file is not there rather than because nobody may read it. The
> first run of `.github/workflows/publish-update-feed.yml` creates it, and
> in-app updates start working the moment it does.

## The versioning rule

`CFBundleShortVersionString` is the version people read. `CFBundleVersion` is
the build number, and **Sparkle decides which release is newer by the build
number alone**. It must only ever go up.

A dev tag names the build number in its suffix: `v0.2.0-dev.31` means
`CFBundleShortVersionString` `0.2.0` and `CFBundleVersion` `31`. A stable
release takes the next number after every preview that came before it, which
`Scripts/release_app.sh` works out for you.

Get this wrong and nothing is loud about it: the release builds, uploads, and
publishes, and simply never reaches anybody. `release_app.sh` refuses a build
number that is not ahead of the current one for exactly that reason.

## Cutting a release

From a clean checkout of `main`, with the changelog's `[Unreleased]` section
saying what changed:

```sh
./Scripts/release_app.sh --dry-run 0.2.0     # prints the plan, writes nothing
./Scripts/release_app.sh 0.2.0               # stable
./Scripts/release_app.sh 0.2.0-dev.31        # preview
```

It bumps `Resources/Info.plist` and the no-bundle fallback in
`Sources/AuspexCore/AuspexVersion.swift`, closes the changelog section with
today's date, commits on `release/<version>`, and creates the tag. It builds
nothing and pushes nothing.

Open the release branch as a pull request, merge it, then push the tag:

```sh
git push origin v0.2.0     # this is what starts the release build
```

`.github/workflows/release.yml` then:

1. checks the tag against the `Info.plist` at that commit and refuses a
   mismatch;
2. runs the full test suite;
3. builds and signs with `Scripts/build_app.sh release`;
4. verifies the signature and refuses a bundle claiming the app sandbox, or one
   missing `Sparkle.framework`;
5. notarizes and staples when the Apple secrets are set, and warns loudly in
   the log when they are not;
6. zips the app, writes a SHA-256, and adds one **signed** appcast item to the
   current feed; and
7. creates or updates a draft release, marking dev drafts as prereleases.

Read the draft. Then press **Publish release** in the GitHub UI.
`.github/workflows/publish-update-feed.yml` takes it from there: it finds the
newest published stable release and the newest published dev release, rebuilds
the whole appcast from those two archives, and commits it to the
machine-managed `updates` branch. Do not edit that branch by hand.

Re-running the release workflow for a tag replaces a **draft's** assets. It
refuses to touch a release that is already published, because a published
release is something a signed appcast item already points at.

## Secrets

Add these as repository Actions secrets (Settings → Secrets and variables →
Actions).

| Secret | Required | What it is |
| --- | --- | --- |
| `SPARKLE_PRIVATE_KEY` | **yes** | The EdDSA private key that signs each appcast item. Without it the release workflow fails before packaging. |
| `MACOS_CERTIFICATE_P12` | no | Base64 of a password-protected Developer ID Application `.p12`. |
| `MACOS_CERTIFICATE_PASSWORD` | with the above | The password used when exporting that `.p12`. |
| `APPLE_ID` | with the above | Apple Developer account email, for `notarytool`. |
| `APPLE_TEAM_ID` | with the above | Apple Developer team ID. |
| `APPLE_APP_PASSWORD` | with the above | App-specific password for `notarytool`. |
| `AUSPEX_BOT_TOKEN` | no | PAT (`contents:write`, `pull_requests:write`) so the kit-bump PR gets CI. |

The four Apple secrets are all-or-nothing: once `MACOS_CERTIFICATE_P12` is
present the workflow requires the rest and fails otherwise. A build signed with
a Developer ID but never notarized is *refused* by Gatekeeper, where an ad-hoc
build is merely awkward to open — half-configured is worse than not configured.

Encode the certificate without printing it:

```sh
base64 -i DeveloperID.p12 | pbcopy
```

Never commit certificates, passwords, Apple IDs, team IDs, or the Sparkle
private key.

## The Sparkle signing key

One EdDSA key pair for the project. The **public** half is compiled into every
build as `SUPublicEDKey` in `Resources/Info.plist`:

```text
zs9VIopKBgtWkMf5APihKchZYDNy3O9dpfpHdZAae14=
```

That is what makes an in-app update safe independently of Apple: Sparkle
verifies the archive's signature against this key *before* unpacking it, so an
archive swapped in transit is refused rather than run.

The **private** half was generated with Sparkle's own tool and lives in the
login Keychain under the account `astroqore-auspex`, on the Mac it was
generated on. An exported copy sits at:

```text
~/.auspex/release/sparkle-private-key.txt      (mode 0600)
```

Paste its contents into the `SPARKLE_PRIVATE_KEY` repository secret, then keep
or delete the file as you prefer — the Keychain copy is the one that matters
locally. It is never printed, never written into a checkout, and never passed
on a command line: both scripts feed it to Sparkle over standard input.

To look the public key up again, or to move the key to another Mac:

```sh
swift package resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account astroqore-auspex -p
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account astroqore-auspex -x key.txt
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account astroqore-auspex -f key.txt
```

Losing the private key means every installed copy stops being able to accept an
update, because they all verify against the public key already compiled into
them. Recovering from that needs a new key pair *and* a new build distributed
some other way.

## Building the feed by hand

`Scripts/generate_update_feed.sh` is what both workflows call. It takes one
already-built archive, checks the tag against the version inside it, adds a
signed item, and asserts that nothing already in the base feed was dropped:

```sh
./Scripts/build_app.sh release
ditto -c -k --sequesterRsrc --keepParent \
  .build/Auspex.app .build/release/Auspex-0.2.0-macOS-arm64.zip

./Scripts/generate_update_feed.sh \
  --channel main --tag v0.2.0 \
  --archive .build/release/Auspex-0.2.0-macOS-arm64.zip \
  --base-appcast /path/to/current/appcast.xml \
  --output .build/release/appcast.xml
```

Locally it signs with the Keychain key (`AUSPEX_SPARKLE_KEY_ACCOUNT`, default
`astroqore-auspex`). In CI it requires `SPARKLE_PRIVATE_KEY`.

## The app sandbox stays off

`Resources/Auspex.entitlements` is an empty plist and both signing paths keep
it that way. Auspex reads session stores scattered across the home directory
and binds `~/.auspex/mcp.sock`; a sandboxed build launches fine and shows an
empty board. `Scripts/build_app.sh` and `release.yml` both refuse a bundle that
claims `com.apple.security.app-sandbox` — see AGENTS.md § 5.
