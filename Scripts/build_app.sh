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

if [[ ! -x "$EXEC_PATH" ]]; then
    echo "Executable not found at $EXEC_PATH" >&2
    exit 1
fi
if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "Entitlements file not found at $ENTITLEMENTS" >&2
    exit 1
fi

echo "==> packaging $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$EXEC_PATH" "$APP_DIR/Contents/MacOS/Auspex"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

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

printf '%s' "APPL????" > "$APP_DIR/Contents/PkgInfo"

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
