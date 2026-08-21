#!/usr/bin/env bash
# Cut an Auspex release: bump the version, close the changelog section, commit
# it on a release branch, and tag it. Pushing the tag is what starts CI, and
# that is the only step this script leaves to a person by default.
#
# Usage:
#   ./Scripts/release_app.sh [--dry-run] [--push] [--force] <version>
#
#   <version>   0.1.0          a stable release  -> tag v0.1.0        (main channel)
#               0.1.0-dev.7    a preview build   -> tag v0.1.0-dev.7  (dev channel)
#
# The dev suffix *is* the build number: tag `v0.1.0-dev.7` means
# CFBundleShortVersionString 0.1.0 and CFBundleVersion 7. Sparkle orders
# releases by CFBundleVersion, so it only ever goes up — a stable release takes
# the next number after every preview that came before it.
#
# What this writes (and what --dry-run only describes):
#   Resources/Info.plist          CFBundleShortVersionString, CFBundleVersion
#   Sources/AuspexCore/AuspexVersion.swift   the no-bundle fallback literals
#   CHANGELOG.md                  [Unreleased] becomes this version, dated
#   a branch release/<version>, one commit on it, and the tag v<version>
#
# It never builds and never uploads. `.github/workflows/release.yml` does both,
# from the tag, so what ships is built from what was tagged rather than from
# whatever happened to be in somebody's checkout.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST="$ROOT/Resources/Info.plist"
VERSION_SWIFT="$ROOT/Sources/AuspexCore/AuspexVersion.swift"
CHANGELOG="$ROOT/CHANGELOG.md"

DRY_RUN=0
PUSH=0
FORCE=0
REQUESTED=""

usage() {
    sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --push) PUSH=1; shift ;;
        --force) FORCE=1; shift ;;
        --help | -h) usage; exit 0 ;;
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 64
            ;;
        *)
            if [[ -n "$REQUESTED" ]]; then
                echo "Only one version may be given, got '$REQUESTED' and '$1'." >&2
                exit 64
            fi
            REQUESTED="$1"
            shift
            ;;
    esac
done

if [[ -z "$REQUESTED" ]]; then
    echo "A version is required, e.g. 0.1.0 or 0.1.0-dev.7" >&2
    usage >&2
    exit 64
fi

# ---------------------------------------------------------------- the version

# Strict on purpose. Everything downstream — the tag, the channel, the appcast
# item, Sparkle's ordering — is derived from this string, so a shape nobody
# planned for has to fail here rather than three steps later in CI.
if [[ "$REQUESTED" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-dev\.([0-9]+)$ ]]; then
    MARKETING_VERSION="${BASH_REMATCH[1]}"
    BUILD_NUMBER="${BASH_REMATCH[2]}"
    CHANNEL="dev"
elif [[ "$REQUESTED" =~ ^([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    MARKETING_VERSION="${BASH_REMATCH[1]}"
    BUILD_NUMBER=""
    CHANNEL="main"
else
    echo "Version must be X.Y.Z or X.Y.Z-dev.N, got: $REQUESTED" >&2
    exit 64
fi

TAG="v$REQUESTED"
BRANCH="release/$REQUESTED"

CURRENT_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
CURRENT_BUILD="$(plutil -extract CFBundleVersion raw -o - "$PLIST")"

if [[ -z "$BUILD_NUMBER" ]]; then
    # A stable release takes the next build number after everything that came
    # before it, previews included. Sparkle compares CFBundleVersion, so a
    # stable release that reused a preview's number would look like a
    # downgrade to the very people who tried the preview.
    BUILD_NUMBER=$((CURRENT_BUILD + 1))
fi

# ------------------------------------------------------------------- the plan

DATE="$(date -u +%Y-%m-%d)"

printf '%s\n' \
    "==> release plan" \
    "    version      $CURRENT_VERSION ($CURRENT_BUILD)  ->  $MARKETING_VERSION ($BUILD_NUMBER)" \
    "    tag          $TAG" \
    "    channel      $CHANNEL" \
    "    branch       $BRANCH" \
    "    changelog    [Unreleased] -> [$REQUESTED] - $DATE" \
    "    files        Resources/Info.plist" \
    "                 Sources/AuspexCore/AuspexVersion.swift" \
    "                 CHANGELOG.md"

# ------------------------------------------------------------- the objections

fail() {
    echo "$1" >&2
    [[ "$DRY_RUN" == "1" ]] && return 0
    exit 1
}

cd "$ROOT"

# Sparkle decides "newer" by CFBundleVersion alone, so this is the one
# objection that would go wrong *silently*: a release that reuses or lowers the
# build number simply never reaches anybody, and nobody finds out for a month.
if [[ "$BUILD_NUMBER" -le "$CURRENT_BUILD" ]]; then
    fail "Build $BUILD_NUMBER is not ahead of the current $CURRENT_BUILD; Sparkle would ignore it."
fi
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    fail "Not a git checkout: $ROOT"
fi
if [[ -n "$(git status --porcelain)" ]]; then
    fail "Working tree is not clean. Commit or stash first."
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    fail "Tag $TAG already exists. A released tag is never moved."
fi
if git rev-parse -q --verify "refs/heads/$BRANCH" >/dev/null && [[ "$FORCE" != "1" ]]; then
    fail "Branch $BRANCH already exists. Delete it or pass --force."
fi
if ! grep -q '^## \[Unreleased\]' "$CHANGELOG"; then
    fail "CHANGELOG.md has no '## [Unreleased]' heading to close."
fi
# A section with a heading and nothing under it is a release whose notes say
# nothing, and the notes are what the GitHub release and the Sparkle item both
# quote. Dev builds are exempt: a preview cut to try one fix is allowed to be
# boring.
if [[ "$CHANNEL" == "main" ]]; then
    UNRELEASED_BODY="$(
        awk '/^## \[Unreleased\]/ { capture = 1; next } /^## \[/ { capture = 0 } capture' \
            "$CHANGELOG" | tr -d '[:space:]'
    )"
    if [[ -z "$UNRELEASED_BODY" ]]; then
        fail "CHANGELOG.md's [Unreleased] section is empty; a stable release needs notes."
    fi
fi

if [[ "$DRY_RUN" == "1" ]]; then
    echo "==> dry run: nothing was written"
    echo "    re-run without --dry-run to write the bump, branch, and tag"
    exit 0
fi

# -------------------------------------------------------------------- the cut

echo "==> bumping Resources/Info.plist"
plutil -replace CFBundleShortVersionString -string "$MARKETING_VERSION" "$PLIST"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$PLIST"

echo "==> bumping the no-bundle fallback in AuspexVersion.swift"
# The literals only ever apply to a run with no Info.plist behind it —
# `swift test`, `swift run` — but a fallback that drifts is a fallback that
# lies in exactly the situation nobody is watching.
/usr/bin/sed -i '' \
    -e "s|^\( *static let fallbackMarketingVersion = \)\"[^\"]*\"|\1\"$MARKETING_VERSION\"|" \
    -e "s|^\( *static let fallbackBuildNumber = \)\"[^\"]*\"|\1\"$BUILD_NUMBER\"|" \
    "$VERSION_SWIFT"
if ! grep -q "fallbackMarketingVersion = \"$MARKETING_VERSION\"" "$VERSION_SWIFT" \
    || ! grep -q "fallbackBuildNumber = \"$BUILD_NUMBER\"" "$VERSION_SWIFT"; then
    echo "AuspexVersion.swift fallbacks were not rewritten; check the file by hand." >&2
    git checkout -- "$PLIST" "$VERSION_SWIFT"
    exit 1
fi

echo "==> closing the changelog section"
python3 - "$CHANGELOG" "$REQUESTED" "$DATE" <<'PY'
import pathlib, sys

path, version, date = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = path.read_text()
heading = "## [Unreleased]"
if heading not in text:
    raise SystemExit("no [Unreleased] heading")
# The empty [Unreleased] goes back in above the closed section, so the next
# change has somewhere to land without anybody having to remember to add it.
text = text.replace(heading, f"{heading}\n\n## [{version}] - {date}", 1)
path.write_text(text)
PY

echo "==> committing on $BRANCH"
git switch --quiet --force-create "$BRANCH"
git add "$PLIST" "$VERSION_SWIFT" "$CHANGELOG"
git commit --quiet --file - <<EOF
chore: release $REQUESTED

Cut by Scripts/release_app.sh. Pushing tag $TAG is what builds and drafts
the release; the draft is published by hand after somebody looks at it.

Channel: $CHANNEL
EOF

echo "==> tagging $TAG"
git tag -a "$TAG" -m "Auspex $REQUESTED"

if [[ "$PUSH" == "1" ]]; then
    echo "==> pushing $BRANCH and $TAG"
    git push origin "$BRANCH"
    git push origin "$TAG"
else
    printf '%s\n' \
        "" \
        "==> not pushed. Nothing has left this machine." \
        "    git push origin $BRANCH" \
        "    git push origin $TAG      # this is what starts the release build" \
        "" \
        "    The workflow leaves a draft release. Read it, then publish it in the" \
        "    GitHub UI — publishing is what rebuilds the update feed."
fi
