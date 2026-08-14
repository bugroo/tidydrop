#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    printf 'Uso: %s DMG (development|community|distribution-pre-notary|distribution)\n' "$0" >&2
    exit 2
fi

DMG=$1
MODE=$2
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
case "$MODE" in development|community|distribution-pre-notary|distribution) ;; *) printf '%s\n' 'ERROR: modo inválido.' >&2; exit 2 ;; esac
[ -f "$DMG" ] && [ ! -L "$DMG" ] || { printf '%s\n' 'ERROR: DMG ausente o inseguro.' >&2; exit 1; }

if [ "$MODE" = 'distribution-pre-notary' ] || [ "$MODE" = 'distribution' ]; then
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
detach_with_retry() {
    detach_attempt=1
    while [ "$detach_attempt" -le 10 ]; do
        if /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1; then
            attached=0
            return 0
        fi
        if [ "$detach_attempt" -lt 10 ]; then
            /bin/sleep 1
        fi
        detach_attempt=$((detach_attempt + 1))
    done
    return 1
}
cleanup() {
    if [ "$attached" -eq 1 ]; then
        if ! detach_with_retry; then
            printf 'AVISO: no se pudo desmontar el DMG temporal: %s\n' "$MOUNT_POINT" >&2
            return
        fi
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
detach_with_retry || {
    printf 'ERROR: no se pudo desmontar el DMG temporal tras 10 intentos: %s\n' "$MOUNT_POINT" >&2
    exit 1
}
printf 'DMG verification: PASS mode=%s\n' "$MODE"
