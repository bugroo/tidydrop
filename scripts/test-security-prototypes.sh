#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
APP_ENTITLEMENTS="$PROJECT_ROOT/app/TidyDrop.entitlements"
AGENT_ENTITLEMENTS="$PROJECT_ROOT/app/TidyDropAgent.entitlements"
PLIST_BUDDY=/usr/libexec/PlistBuddy

[ -x "$PLIST_BUDDY" ] || {
    printf '%s\n' 'ERROR: native PlistBuddy is unavailable.' >&2
    exit 1
}

/usr/bin/plutil -lint "$APP_ENTITLEMENTS"
/usr/bin/plutil -lint "$AGENT_ENTITLEMENTS"

for entitlement_file in "$APP_ENTITLEMENTS" "$AGENT_ENTITLEMENTS"; do
    "$PLIST_BUDDY" -c 'Print :com.apple.security.app-sandbox' "$entitlement_file" \
        | /usr/bin/grep -qx true
    "$PLIST_BUDDY" -c 'Print :com.apple.security.files.bookmarks.app-scope' \
        "$entitlement_file" | /usr/bin/grep -qx true
    if /usr/bin/grep -q 'com.apple.security.network' "$entitlement_file"; then
        printf '%s\n' 'ERROR: sandbox prototype must not receive network entitlements.' >&2
        exit 1
    fi
done
"$PLIST_BUDDY" -c 'Print :com.apple.security.files.user-selected.read-write' \
    "$APP_ENTITLEMENTS" | /usr/bin/grep -qx true
if "$PLIST_BUDDY" -c 'Print :com.apple.security.files.user-selected.read-write' \
    "$AGENT_ENTITLEMENTS" >/dev/null 2>&1; then
    printf '%s\n' 'ERROR: only the UI may receive Powerbox-selected access.' >&2
    exit 1
fi

SDK_PATH=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
for prototype_arch in arm64 x86_64; do
    /usr/bin/printf '%s\n' \
        'import Foundation' \
        'func applyRequirement(_ connection: NSXPCConnection) {' \
        '    connection.setCodeSigningRequirement("identifier \"io.github.bugroo.tidydrop\"")' \
        '}' \
        | /usr/bin/xcrun --sdk macosx swiftc \
            -sdk "$SDK_PATH" \
            -target "$prototype_arch-apple-macosx13.0" \
            -warnings-as-errors \
            -typecheck -
done

PROBE_ROOT=$(/usr/bin/mktemp -d "/private/tmp/TidyDropIntegration.security-prototype.XXXXXX")
case "$PROBE_ROOT" in
    /private/tmp/TidyDropIntegration.security-prototype.*) ;;
    *) printf '%s\n' 'ERROR: unsafe security prototype root' >&2; exit 1 ;;
esac
trap '/bin/rm -rf "$PROBE_ROOT"' EXIT HUP INT TERM

PROBE_BINARY=${TIDYDROP_SELF_TEST_BIN:-"$PROJECT_ROOT/.build/debug/tidydrop-self-test"}
[ -x "$PROBE_BINARY" ] || {
    printf '%s\n' 'ERROR: self-test binary missing for entitlement-signing prototype.' >&2
    exit 1
}
/bin/cp "$PROBE_BINARY" "$PROBE_ROOT/sandbox-signature-probe"
/usr/bin/codesign --force --sign - --timestamp=none \
    --entitlements "$APP_ENTITLEMENTS" "$PROBE_ROOT/sandbox-signature-probe"
/usr/bin/codesign --verify --strict "$PROBE_ROOT/sandbox-signature-probe"
PROBE_ENTITLEMENTS=$(/usr/bin/codesign --display --entitlements - \
    "$PROBE_ROOT/sandbox-signature-probe" 2>&1)
printf '%s\n' "$PROBE_ENTITLEMENTS" | /usr/bin/grep -q 'com.apple.security.app-sandbox'
printf '%s\n' "$PROBE_ENTITLEMENTS" | /usr/bin/grep -q \
    'com.apple.security.files.bookmarks.app-scope'
printf '%s\n' "$PROBE_ENTITLEMENTS" | /usr/bin/grep -q \
    'com.apple.security.files.user-selected.read-write'

printf '%s\n' 'XPC, code-signing requirement, bookmark, and sandbox entitlement prototypes: PASS'
printf '%s\n' 'Sandbox rollout remains disabled for release bundles until persistent agent access is proven.'
