#!/bin/sh
set -eu

umask 077

if [ "$#" -ne 3 ] || [ "$2" != '--keychain-profile' ]; then
    printf 'Uso: %s DMG --keychain-profile PERFIL\n' "$0" >&2
    exit 2
fi

DMG=$1
PROFILE=$3
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ -f "$DMG" ] && [ ! -L "$DMG" ] || { printf '%s\n' 'ERROR: DMG ausente o inseguro.' >&2; exit 1; }
[ -n "$PROFILE" ] || { printf '%s\n' 'ERROR: perfil vacío.' >&2; exit 2; }

DMG_SIGNATURE=$(/usr/bin/codesign --display --verbose=4 "$DMG" 2>&1 || true)
printf '%s\n' "$DMG_SIGNATURE" | /usr/bin/grep -q '^Authority=Developer ID Application:' || {
    printf '%s\n' 'ERROR: notarización bloqueada; el DMG no tiene Developer ID Application.' >&2
    exit 1
}
printf '%s\n' "$DMG_SIGNATURE" | /usr/bin/grep -q '^Timestamp=' || {
    printf '%s\n' 'ERROR: notarización bloqueada; el DMG no tiene timestamp seguro.' >&2
    exit 1
}

NOTARY_ROOT=$(/usr/bin/mktemp -d "/private/tmp/TidyDropDMG.notary.XXXXXX")
trap '/bin/rm -rf "$NOTARY_ROOT"' EXIT HUP INT TERM
RESULT_PLIST="$NOTARY_ROOT/result.plist"
/usr/bin/xcrun notarytool submit "$DMG" \
    --keychain-profile "$PROFILE" \
    --wait \
    --timeout 30m \
    --no-progress \
    --output-format plist >"$RESULT_PLIST"

STATUS=$(/usr/bin/plutil -extract status raw -o - "$RESULT_PLIST")
SUBMISSION_ID=$(/usr/bin/plutil -extract id raw -o - "$RESULT_PLIST")
[ "$STATUS" = 'Accepted' ] || {
    printf 'ERROR: notarización del DMG no aceptada; status=%s id=%s\n' "$STATUS" "$SUBMISSION_ID" >&2
    exit 1
}

/usr/bin/xcrun stapler staple "$DMG"
"$SCRIPT_DIR/verify-dmg.sh" "$DMG" distribution
printf 'DMG notarizado y grapado; id=%s\n' "$SUBMISSION_ID"
