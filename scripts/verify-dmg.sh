#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    printf 'Uso: %s DMG (development|distribution-pre-notary|distribution)\n' "$0" >&2
    exit 2
fi

DMG=$1
MODE=$2
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
case "$MODE" in development|distribution-pre-notary|distribution) ;; *) printf '%s\n' 'ERROR: modo inválido.' >&2; exit 2 ;; esac
[ -f "$DMG" ] && [ ! -L "$DMG" ] || { printf '%s\n' 'ERROR: DMG ausente o inseguro.' >&2; exit 1; }

if [ "$MODE" != 'development' ]; then
    DMG_SIGNATURE=$(/usr/bin/codesign --display --verbose=4 "$DMG" 2>&1)
    printf '%s\n' "$DMG_SIGNATURE" | /usr/bin/grep -q '^Authority=Developer ID Application:' || {
        printf '%s\n' 'ERROR: el DMG no tiene firma Developer ID Application.' >&2
        exit 1
    }
    printf '%s\n' "$DMG_SIGNATURE" | /usr/bin/grep -q '^Timestamp=' || {
        printf '%s\n' 'ERROR: el DMG no tiene timestamp seguro.' >&2
        exit 1
    }
    if [ "$MODE" = 'distribution' ]; then
        /usr/bin/xcrun stapler validate "$DMG"
        /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
    fi
fi

VERIFY_ROOT=$(/usr/bin/mktemp -d "/private/tmp/TidyDropDMG.verify.XXXXXX")
MOUNT_POINT="$VERIFY_ROOT/mount"
/bin/mkdir -p "$MOUNT_POINT"
attached=0
cleanup() {
    if [ "$attached" -eq 1 ]; then
        /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
    fi
    /bin/rm -rf "$VERIFY_ROOT"
}
trap cleanup EXIT HUP INT TERM

/usr/bin/hdiutil attach "$DMG" -readonly -nobrowse -noautoopen -mountpoint "$MOUNT_POINT" -quiet
attached=1
[ -d "$MOUNT_POINT/TidyDrop.app" ] || { printf '%s\n' 'ERROR: falta TidyDrop.app en el DMG.' >&2; exit 1; }
[ -L "$MOUNT_POINT/Applications" ] || { printf '%s\n' 'ERROR: falta el enlace Applications.' >&2; exit 1; }
[ "$(/usr/bin/readlink "$MOUNT_POINT/Applications")" = '/Applications' ] || {
    printf '%s\n' 'ERROR: el enlace Applications no apunta a /Applications.' >&2
    exit 1
}
APP_MODE=$MODE
[ "$MODE" = 'distribution-pre-notary' ] && APP_MODE=distribution
"$SCRIPT_DIR/verify-release.sh" "$MOUNT_POINT/TidyDrop.app" "$APP_MODE"
/usr/bin/hdiutil detach "$MOUNT_POINT" -quiet
attached=0
printf 'DMG verification: PASS mode=%s\n' "$MODE"
