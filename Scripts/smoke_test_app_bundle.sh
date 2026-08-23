#!/usr/bin/env bash
# Prove that a packaged Auspex can load its SwiftPM resources without the
# absolute build-machine fallback compiled into Bundle.module.
#
# Usage: bash Scripts/smoke_test_app_bundle.sh <Auspex.app> <SwiftPM resource bundle>
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <Auspex.app> <SwiftPM resource bundle>" >&2
    exit 64
fi

SOURCE_APP="$1"
FALLBACK_BUNDLE="$2"

if [[ ! -x "$SOURCE_APP/Contents/MacOS/Auspex" ]]; then
    echo "Packaged Auspex executable not found in $SOURCE_APP" >&2
    exit 1
fi
if [[ ! -d "$FALLBACK_BUNDLE" ]]; then
    echo "SwiftPM fallback bundle not found at $FALLBACK_BUNDLE" >&2
    exit 1
fi

SMOKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/auspex-app-smoke.XXXXXX")"
SMOKE_APP="$SMOKE_ROOT/Auspex.app"
HIDDEN_FALLBACK="${FALLBACK_BUNDLE}.auspex-smoke-hidden-$$"

cleanup() {
    if [[ -d "$HIDDEN_FALLBACK" && ! -e "$FALLBACK_BUNDLE" ]]; then
        mv "$HIDDEN_FALLBACK" "$FALLBACK_BUNDLE"
    fi
    rm -rf "$SMOKE_ROOT"
}
trap cleanup EXIT INT TERM

if [[ -e "$HIDDEN_FALLBACK" ]]; then
    echo "Refusing to overwrite an existing smoke-test path: $HIDDEN_FALLBACK" >&2
    exit 1
fi

# Run a copy so the test has the same shape as a downloaded archive rather
# than accidentally relying on the app's position inside the checkout.
ditto "$SOURCE_APP" "$SMOKE_APP"

# If the executable ever falls through to Bundle.module, its generated
# accessor will now fail instead of finding the original compiler output.
mv "$FALLBACK_BUNDLE" "$HIDDEN_FALLBACK"

echo "==> smoke testing packaged app resources with SwiftPM fallback hidden"
output="$("$SMOKE_APP/Contents/MacOS/Auspex" --smoke-app-resources)"
echo "$output"
if [[ "$output" != *"from application"* ]]; then
    echo "Packaged resource smoke did not resolve through Contents/Resources." >&2
    exit 1
fi
