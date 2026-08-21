#!/usr/bin/env bash
# Add one release archive to a signed Sparkle appcast, preserving what is
# already in it.
#
# Usage:
#   ./Scripts/generate_update_feed.sh \
#     --channel main|dev --tag <tag> --archive <zip> --output <appcast.xml> \
#     [--base-appcast <appcast.xml>]
#
# Two callers, one script:
#
#   release.yml           adds the freshly built archive to the current feed so
#                         the draft release carries a usable appcast asset.
#   publish-update-feed.yml  runs it once per channel head over the *published*
#                         releases and commits the result to the `updates`
#                         branch, which is the feed every installed copy reads.
#
# The second is the one that matters, and the reason it rebuilds from published
# releases rather than appending as events arrive: GitHub Actions concurrency
# is not an event queue. A run that gets replaced while queued would otherwise
# take a release out of the feed with it. Reconstructing both channel heads
# from what is actually published means the last run to finish is always right.
#
# Signing: SPARKLE_PRIVATE_KEY (the EdDSA private key, fed on stdin, never on
# the command line and never written into the checkout), or — locally — the
# key in the login Keychain under AUSPEX_SPARKLE_KEY_ACCOUNT.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARKLE_KEY_ACCOUNT="${AUSPEX_SPARKLE_KEY_ACCOUNT:-astroqore-auspex}"
DOWNLOAD_PREFIX_BASE="${AUSPEX_RELEASE_URL_BASE:-https://github.com/AstroQore/auspex/releases}"
RELEASE_CHANNEL=""
RELEASE_TAG=""
ARCHIVE=""
BASE_APPCAST=""
OUTPUT=""

usage() {
    printf '%s\n' \
        "Add a release archive to a signed Sparkle appcast." \
        "" \
        "Usage: ./Scripts/generate_update_feed.sh \\" \
        "  --channel main|dev --tag <tag> --archive <zip> --output <appcast.xml> \\" \
        "  [--base-appcast <appcast.xml>]"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --channel)
            [[ $# -ge 2 ]] || { echo "--channel requires main or dev" >&2; exit 64; }
            RELEASE_CHANNEL="$2"; shift 2 ;;
        --tag)
            [[ $# -ge 2 ]] || { echo "--tag requires a release tag" >&2; exit 64; }
            RELEASE_TAG="$2"; shift 2 ;;
        --archive)
            [[ $# -ge 2 ]] || { echo "--archive requires a ZIP path" >&2; exit 64; }
            ARCHIVE="$2"; shift 2 ;;
        --base-appcast)
            [[ $# -ge 2 ]] || { echo "--base-appcast requires an appcast path" >&2; exit 64; }
            BASE_APPCAST="$2"; shift 2 ;;
        --output)
            [[ $# -ge 2 ]] || { echo "--output requires an appcast path" >&2; exit 64; }
            OUTPUT="$2"; shift 2 ;;
        --help | -h) usage; exit 0 ;;
        *)
            echo "Unknown or incomplete option: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

if [[ "$RELEASE_CHANNEL" != "main" && "$RELEASE_CHANNEL" != "dev" ]]; then
    echo "--channel must be main or dev" >&2
    exit 64
fi
if [[ -z "$RELEASE_TAG" || -z "$ARCHIVE" || -z "$OUTPUT" ]]; then
    echo "--tag, --archive, and --output are required" >&2
    exit 64
fi
if [[ ! -f "$ARCHIVE" ]]; then
    echo "Release archive not found at $ARCHIVE" >&2
    exit 1
fi
if [[ -n "$BASE_APPCAST" && ! -f "$BASE_APPCAST" ]]; then
    echo "Base appcast not found at $BASE_APPCAST" >&2
    exit 1
fi

GENERATE_APPCAST="$(
    find "$ROOT/.build/artifacts/sparkle" \
        -type f \
        -path '*/Sparkle/bin/generate_appcast' \
        -print \
        -quit
)"
if [[ -z "$GENERATE_APPCAST" || ! -x "$GENERATE_APPCAST" ]]; then
    echo "Sparkle's generate_appcast was not found." >&2
    echo "Run 'swift package resolve' first; it arrives with the Sparkle artifact." >&2
    exit 1
fi

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/auspex-update-feed.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_ARCHIVE="$STAGING_DIR/$(basename "$ARCHIVE")"
cp "$ARCHIVE" "$STAGED_ARCHIVE"

# The tag is checked against the version *inside the archive*, not against
# whatever Info.plist happens to be in the checkout. A feed item that claims a
# version the download does not contain is an update loop: Sparkle offers it,
# installs it, and finds the same old version still asking.
EXTRACTED_DIR="$STAGING_DIR/extracted"
mkdir -p "$EXTRACTED_DIR"
ditto -x -k "$STAGED_ARCHIVE" "$EXTRACTED_DIR"
ARCHIVE_PLIST="$(
    find "$EXTRACTED_DIR" \
        -mindepth 3 \
        -maxdepth 3 \
        -type f \
        -path '*.app/Contents/Info.plist' \
        -print \
        -quit
)"
if [[ -z "$ARCHIVE_PLIST" ]]; then
    echo "Release archive does not contain an app Info.plist." >&2
    exit 1
fi
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$ARCHIVE_PLIST")"
BUILD_NUMBER="$(plutil -extract CFBundleVersion raw -o - "$ARCHIVE_PLIST")"
if [[ "$RELEASE_CHANNEL" == "main" ]]; then
    EXPECTED_TAG="v$VERSION"
else
    EXPECTED_TAG="v$VERSION-dev.$BUILD_NUMBER"
fi
if [[ "$RELEASE_TAG" != "$EXPECTED_TAG" ]]; then
    echo "Release tag $RELEASE_TAG does not match the archived build $EXPECTED_TAG." >&2
    exit 1
fi

if [[ -n "$BASE_APPCAST" ]]; then
    cp "$BASE_APPCAST" "$STAGING_DIR/appcast.xml"
fi

# `generate_appcast` embeds a sibling .md as the item's release notes. One
# short line pointing at the tag, rather than the changelog inlined: the notes
# render inside Sparkle's small update window, and the GitHub release is where
# the full text already lives.
RELEASE_NOTES="$STAGING_DIR/$(basename "${STAGED_ARCHIVE%.zip}").md"
printf '# Auspex %s\n\nSee the [full release notes](%s/tag/%s).\n' \
    "$VERSION" "$DOWNLOAD_PREFIX_BASE" "$RELEASE_TAG" > "$RELEASE_NOTES"

APPCAST_ARGS=(
    --download-url-prefix "$DOWNLOAD_PREFIX_BASE/download/$RELEASE_TAG/"
    --link "$DOWNLOAD_PREFIX_BASE/tag/$RELEASE_TAG"
    --embed-release-notes
    # Keep every item. Pruning is what would drop the *other* channel's head,
    # because this script only ever sees one channel at a time.
    --maximum-versions 0
    -o "$STAGING_DIR/appcast.xml"
)
if [[ "$RELEASE_CHANNEL" == "dev" ]]; then
    APPCAST_ARGS+=(--channel dev)
fi

if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    printf '%s' "$SPARKLE_PRIVATE_KEY" \
        | "$GENERATE_APPCAST" --ed-key-file - "${APPCAST_ARGS[@]}" "$STAGING_DIR"
elif [[ "${CI:-}" == "true" ]]; then
    echo "SPARKLE_PRIVATE_KEY is required in CI." >&2
    exit 1
else
    "$GENERATE_APPCAST" \
        --account "$SPARKLE_KEY_ACCOUNT" \
        "${APPCAST_ARGS[@]}" \
        "$STAGING_DIR"
fi

APPCAST="$STAGING_DIR/appcast.xml"
if ! grep -q 'sparkle:edSignature=' "$APPCAST"; then
    echo "Generated appcast has no EdDSA signature; refusing to publish it." >&2
    exit 1
fi
if ! grep -q "<sparkle:version>$BUILD_NUMBER</sparkle:version>" "$APPCAST"; then
    echo "Generated appcast does not contain build $BUILD_NUMBER." >&2
    exit 1
fi
if [[ "$RELEASE_CHANNEL" == "dev" ]] \
    && ! grep -q '<sparkle:channel>dev</sparkle:channel>' "$APPCAST"; then
    echo "Generated appcast does not mark build $BUILD_NUMBER as dev." >&2
    exit 1
fi
# Every build the base feed carried has to still be there. This is the
# assertion that makes "both channel heads survive" a property of the script
# rather than a hope about how generate_appcast merges.
if [[ -n "$BASE_APPCAST" ]]; then
    while IFS= read -r base_version; do
        if ! grep -q "<sparkle:version>$base_version</sparkle:version>" "$APPCAST"; then
            echo "Generated appcast dropped existing build $base_version." >&2
            exit 1
        fi
    done < <(
        sed -n 's|.*<sparkle:version>\([^<]*\)</sparkle:version>.*|\1|p' "$BASE_APPCAST"
    )
fi
if ! xmllint --noout "$APPCAST" 2>/dev/null; then
    echo "Generated appcast is not well-formed XML." >&2
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
cp "$APPCAST" "$OUTPUT"
echo "Sparkle appcast ready: $OUTPUT"
