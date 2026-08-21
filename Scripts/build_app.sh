#!/usr/bin/env bash
# Build the Auspex executable, wrap it into a proper .app bundle, and sign it.
# Usage: ./Scripts/build_app.sh [debug|release]
# Output: .build/Auspex.app
#
# Signing defaults to ad-hoc for local builds. Release automation can set
# AUSPEX_CODESIGN_IDENTITY to a Developer ID Application identity; the same
# (deliberately empty) entitlements apply in both modes, so the packaged app
# stays unsandboxed either way. See Resources/Auspex.entitlements.
set -euo pipefail

CONFIG="${1:-release}"
case "$CONFIG" in
    debug | release) ;;
    *)
        echo "Usage: $0 [debug|release]" >&2
        exit 64
        ;;
esac

SIGN_IDENTITY="${AUSPEX_CODESIGN_IDENTITY:--}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
EXEC_PATH="$BIN_DIR/Auspex"
APP_DIR="$ROOT/.build/Auspex.app"
ENTITLEMENTS="$ROOT/Resources/Auspex.entitlements"
SPARKLE_FRAMEWORK="$APP_DIR/Contents/Frameworks/Sparkle.framework"
# Sparkle ships as a binary xcframework, so SwiftPM leaves it in the artifacts
# directory rather than building it. The path carries the version, which is why
# it is searched for rather than written down twice.
SPARKLE_SOURCE="$(
    find "$ROOT/.build/artifacts/sparkle" \
        -type d \
        -path '*/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework' \
        -print \
        -quit
)"

if [[ ! -x "$EXEC_PATH" ]]; then
    echo "Executable not found at $EXEC_PATH" >&2
    exit 1
fi
if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "Entitlements file not found at $ENTITLEMENTS" >&2
    exit 1
fi
if [[ -z "$SPARKLE_SOURCE" || ! -x "$SPARKLE_SOURCE/Versions/B/Sparkle" ]]; then
    echo "Sparkle framework artifact not found after SwiftPM build." >&2
    echo "Run 'swift package resolve' and try again." >&2
    exit 1
fi

echo "==> packaging $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Frameworks"

cp "$EXEC_PATH" "$APP_DIR/Contents/MacOS/Auspex"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
# `ditto` rather than `cp -R`: a framework is a bundle of symlinks
# (`Versions/Current`, the top-level `Sparkle`), and a copy that turned them
# into duplicate files would be a bundle codesign refuses to seal.
echo "==> bundling Sparkle.framework"
ditto "$SPARKLE_SOURCE" "$SPARKLE_FRAMEWORK"

# A signed macOS app may only contain its conventional Contents tree, so any
# SwiftPM resource bundle has to be copied under Contents/Resources rather
# than left beside the binary. There are none yet; this loop keeps working
# when a target gains a `resources:` declaration.
shopt -s nullglob
for bundle in "$BIN_DIR"/Auspex_*.bundle; do
    echo "==> bundling $(basename "$bundle")"
    cp -R "$bundle" "$APP_DIR/Contents/Resources/$(basename "$bundle")"
done
shopt -u nullglob

# The icon is optional: pre-alpha builds ship without artwork.
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# The character packages the office draws its people from (docs/CHARACTERS.md).
# Copied whole rather than declared as a SwiftPM resource: they are already the
# exact bytes to ship, the folder structure *is* the format, and art lands one
# pose at a time — a build that failed because a declared resource directory was
# still empty would stop the app for the sake of a PNG nobody had drawn yet.
if [[ -d "$ROOT/Resources/Characters" ]]; then
    echo "==> bundling character packages"
    cp -R "$ROOT/Resources/Characters" "$APP_DIR/Contents/Resources/Characters"
fi

# The rest of the shipped art: tilesets and atlases the scene draws rooms from
# (docs/ART-HANDOFF.md § 5–8), the menu bar template images, the in-app icon
# set, and the empty-state / onboarding illustrations. Same reasoning as the
# characters: the files are the format, and a folder is copied only if it
# exists, so a build never waits on art.
for art in Tiles MenuBar Icons UI; do
    if [[ -d "$ROOT/Resources/$art" ]]; then
        echo "==> bundling $art"
        cp -R "$ROOT/Resources/$art" "$APP_DIR/Contents/Resources/$art"
    fi
done

printf '%s' "APPL????" > "$APP_DIR/Contents/PkgInfo"

# Nested code is sealed inside-out: every helper Sparkle carries has to be
# signed before the framework, and the framework before the app, or the app's
# seal covers a signature that is about to change. Sparkle's own Developer ID
# signature does not survive being copied here anyway — the app around it is
# signed with a different identity, and `--deep --strict` checks each one.
SPARKLE_VERSION_DIR="$SPARKLE_FRAMEWORK/Versions/B"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    SPARKLE_SIGN_ARGS=(--force --sign - --options runtime)
else
    SPARKLE_SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --options runtime --timestamp)
fi

echo "==> signing Sparkle helper components"
codesign "${SPARKLE_SIGN_ARGS[@]}" "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc"
# The downloader is the one piece of Sparkle that is itself sandboxed, so its
# entitlements are kept rather than replaced with ours.
codesign \
    "${SPARKLE_SIGN_ARGS[@]}" \
    --preserve-metadata=entitlements \
    "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc"
codesign "${SPARKLE_SIGN_ARGS[@]}" "$SPARKLE_VERSION_DIR/Autoupdate"
codesign "${SPARKLE_SIGN_ARGS[@]}" "$SPARKLE_VERSION_DIR/Updater.app"
codesign "${SPARKLE_SIGN_ARGS[@]}" "$SPARKLE_FRAMEWORK"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "==> ad-hoc codesign with entitlements"
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_DIR"
else
    echo "==> Developer ID codesign with hardened runtime"
    codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$SIGN_IDENTITY" \
        --entitlements "$ENTITLEMENTS" \
        "$APP_DIR"
fi

codesign --verify --deep --strict "$APP_DIR"

# Auspex must stay unsandboxed: a sandboxed app cannot read the harness
# session stores it exists to observe, and the failure mode is a silent
# empty board rather than a crash. Assert it here so a stray entitlement
# can never reach a build unnoticed.
echo "==> verifying no app-sandbox entitlement"
SIGNED_ENTITLEMENTS="$(codesign -dv --entitlements - "$APP_DIR" 2>&1)"
if grep -q "com.apple.security.app-sandbox" <<< "$SIGNED_ENTITLEMENTS"; then
    echo "Refusing to ship: the signed bundle claims com.apple.security.app-sandbox." >&2
    echo "$SIGNED_ENTITLEMENTS" >&2
    exit 1
fi

echo "==> done: $APP_DIR"
echo "Run with: open \"$APP_DIR\""
