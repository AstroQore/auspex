#!/usr/bin/env bash
# Prove that a packaged Auspex can load its SwiftPM resources without the
# absolute build-machine fallback compiled into Bundle.module.
#
# Usage: bash Scripts/smoke_test_app_bundle.sh <Auspex.app> <SwiftPM resource bundle> \
#            [<auspex-i18n resource bundle>]
#
# With the third argument the string catalogue's build-machine bundle is
# hidden as well, and the packaged app has to serve a Simplified Chinese
# string out of its own Contents/Resources.
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: $0 <Auspex.app> <SwiftPM resource bundle> [<auspex-i18n resource bundle>]" >&2
    exit 64
fi

SOURCE_APP="$1"
FALLBACK_BUNDLE="$2"
I18N_BUNDLE="${3:-}"

if [[ ! -x "$SOURCE_APP/Contents/MacOS/Auspex" ]]; then
    echo "Packaged Auspex executable not found in $SOURCE_APP" >&2
    exit 1
fi
if [[ ! -d "$FALLBACK_BUNDLE" ]]; then
    echo "SwiftPM fallback bundle not found at $FALLBACK_BUNDLE" >&2
    exit 1
fi
if [[ -n "$I18N_BUNDLE" && ! -d "$I18N_BUNDLE" ]]; then
    echo "Localization fallback bundle not found at $I18N_BUNDLE" >&2
    exit 1
fi

SMOKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/auspex-app-smoke.XXXXXX")"
SMOKE_APP="$SMOKE_ROOT/Auspex.app"
HIDDEN_FALLBACK="${FALLBACK_BUNDLE}.auspex-smoke-hidden-$$"
HIDDEN_I18N="${I18N_BUNDLE:+${I18N_BUNDLE}.auspex-smoke-hidden-$$}"

cleanup() {
    if [[ -d "$HIDDEN_FALLBACK" && ! -e "$FALLBACK_BUNDLE" ]]; then
        mv "$HIDDEN_FALLBACK" "$FALLBACK_BUNDLE"
    fi
    if [[ -n "$HIDDEN_I18N" && -d "$HIDDEN_I18N" && ! -e "$I18N_BUNDLE" ]]; then
        mv "$HIDDEN_I18N" "$I18N_BUNDLE"
    fi
    rm -rf "$SMOKE_ROOT"
}
trap cleanup EXIT INT TERM

if [[ -e "$HIDDEN_FALLBACK" || ( -n "$HIDDEN_I18N" && -e "$HIDDEN_I18N" ) ]]; then
    echo "Refusing to overwrite an existing smoke-test path beside $FALLBACK_BUNDLE" >&2
    exit 1
fi

# Run a copy so the test has the same shape as a downloaded archive rather
# than accidentally relying on the app's position inside the checkout.
ditto "$SOURCE_APP" "$SMOKE_APP"

# If the executable ever falls through to Bundle.module, its generated
# accessor will now fail instead of finding the original compiler output.
mv "$FALLBACK_BUNDLE" "$HIDDEN_FALLBACK"
if [[ -n "$HIDDEN_I18N" ]]; then
    mv "$I18N_BUNDLE" "$HIDDEN_I18N"
fi

echo "==> smoke testing packaged app resources with SwiftPM fallback hidden"
output="$("$SMOKE_APP/Contents/MacOS/Auspex" --smoke-app-resources)"
echo "$output"
if [[ "$output" != *"critical resources from application"* ]]; then
    echo "Packaged resource smoke did not resolve through Contents/Resources." >&2
    exit 1
fi
if [[ -n "$I18N_BUNDLE" && "$output" != *"localization zh-Hans from application"* ]]; then
    echo "Packaged localization smoke did not serve zh-Hans from Contents/Resources." >&2
    exit 1
fi
