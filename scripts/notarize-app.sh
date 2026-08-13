#!/bin/sh
set -eu

umask 077

if [ "$#" -ne 3 ] || [ "$2" != '--keychain-profile' ]; then
    printf 'Uso: %s APP --keychain-profile PERFIL\n' "$0" >&2
    exit 2
fi

APP=$1
PROFILE=$3
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
EXPECTED_BUNDLE_ID=${TIDYDROP_RELEASE_BUNDLE_ID:-}
EXPECTED_TEAM_ID=${TIDYDROP_RELEASE_TEAM_ID:-}

[ -d "$APP" ] && [ ! -L "$APP" ] || {
    printf 'ERROR: bundle ausente o inseguro: %s\n' "$APP" >&2
    exit 1
}
[ -n "$PROFILE" ] || {
    printf '%s\n' 'ERROR: el perfil de Keychain no puede estar vacío.' >&2
    exit 2
}
[ -n "$EXPECTED_BUNDLE_ID" ] && [ -n "$EXPECTED_TEAM_ID" ] || {
    printf '%s\n' 'ERROR: faltan TIDYDROP_RELEASE_BUNDLE_ID o TIDYDROP_RELEASE_TEAM_ID.' >&2
    exit 1
}
case "$EXPECTED_BUNDLE_ID" in
    ''|.*|*..*|*[!A-Za-z0-9.-]*|*.)
        printf '%s\n' 'ERROR: bundle ID esperado inválido.' >&2
        exit 1
        ;;
    com.local.*|com.example.*)
        printf '%s\n' 'ERROR: el bundle ID de distribución no puede ser local o de ejemplo.' >&2
        exit 1
        ;;
esac
case "$EXPECTED_BUNDLE_ID" in
    *.*) ;;
    *) printf '%s\n' 'ERROR: bundle ID esperado inválido.' >&2; exit 1 ;;
esac
case "$EXPECTED_TEAM_ID" in
    *[!A-Z0-9]*|'')
        printf '%s\n' 'ERROR: Team ID inválido; se esperan 10 caracteres A-Z/0-9.' >&2
        exit 1
        ;;
esac
[ "${#EXPECTED_TEAM_ID}" -eq 10 ] || {
    printf '%s\n' 'ERROR: Team ID inválido; se esperan 10 caracteres A-Z/0-9.' >&2
    exit 1
}

# Fallar antes de cualquier subida si la firma local no reúne los gates base.
SIGNATURE_INFO=$(/usr/bin/codesign --display --verbose=4 "$APP" 2>&1)
printf '%s\n' "$SIGNATURE_INFO" | /usr/bin/grep -q '^Authority=Developer ID Application:' || {
    printf '%s\n' 'ERROR: notarización bloqueada; falta firma Developer ID Application.' >&2
    exit 1
}
printf '%s\n' "$SIGNATURE_INFO" | /usr/bin/grep -q '^Timestamp=' || {
    printf '%s\n' 'ERROR: notarización bloqueada; falta timestamp seguro.' >&2
    exit 1
}
printf '%s\n' "$SIGNATURE_INFO" | /usr/bin/grep -E 'flags=.*runtime' >/dev/null || {
    printf '%s\n' 'ERROR: notarización bloqueada; falta Hardened Runtime.' >&2
    exit 1
}
ACTUAL_TEAM_ID=$(printf '%s\n' "$SIGNATURE_INFO" \
    | /usr/bin/awk -F= '$1 == "TeamIdentifier" { print substr($0, index($0, "=") + 1); exit }')
[ "$ACTUAL_TEAM_ID" = "$EXPECTED_TEAM_ID" ] || {
    printf '%s\n' 'ERROR: notarización bloqueada; Team ID inesperado.' >&2
    exit 1
}
ACTUAL_BUNDLE_ID=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")
[ "$ACTUAL_BUNDLE_ID" = "$EXPECTED_BUNDLE_ID" ] || {
    printf 'ERROR: notarización bloqueada; bundle ID %s, esperado %s.\n' \
        "$ACTUAL_BUNDLE_ID" "$EXPECTED_BUNDLE_ID" >&2
    exit 1
}
ENTITLEMENTS=$(/usr/bin/codesign --display --entitlements - "$APP" 2>&1 || true)
if printf '%s\n' "$ENTITLEMENTS" | /usr/bin/grep -q 'com.apple.security.get-task-allow'; then
    printf '%s\n' 'ERROR: notarización bloqueada; get-task-allow está presente.' >&2
    exit 1
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"

NOTARY_ROOT=$(/usr/bin/mktemp -d "/private/tmp/TidyDropNotary.submit.XXXXXX")
trap '/bin/rm -rf "$NOTARY_ROOT"' EXIT HUP INT TERM
SUBMISSION="$NOTARY_ROOT/TidyDrop.zip"
RESULT_PLIST="$NOTARY_ROOT/notary-result.plist"

/usr/bin/ditto -c -k --keepParent "$APP" "$SUBMISSION"
/usr/bin/xcrun notarytool submit "$SUBMISSION" \
    --keychain-profile "$PROFILE" \
    --wait \
    --timeout 30m \
    --no-progress \
    --output-format plist >"$RESULT_PLIST"

STATUS=$(/usr/bin/plutil -extract status raw -o - "$RESULT_PLIST")
SUBMISSION_ID=$(/usr/bin/plutil -extract id raw -o - "$RESULT_PLIST")
[ "$STATUS" = 'Accepted' ] || {
    printf 'ERROR: notarización no aceptada; status=%s id=%s\n' "$STATUS" "$SUBMISSION_ID" >&2
    exit 1
}

/usr/bin/xcrun stapler staple "$APP"
/usr/bin/xcrun stapler validate "$APP"
printf 'Notarización aceptada y ticket grapado; id=%s\n' "$SUBMISSION_ID"
