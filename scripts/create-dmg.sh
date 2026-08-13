#!/bin/sh
set -eu

umask 077

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    printf 'Uso: %s APP DMG_SALIDA (development|community|distribution) [IDENTIDAD_DEVELOPER_ID]\n' "$0" >&2
    exit 2
fi

APP=$1
OUTPUT_DMG=$2
MODE=$3
IDENTITY=${4:-}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

case "$MODE" in
    development|community)
        [ -z "$IDENTITY" ] || { printf '%s\n' 'ERROR: el canal ad hoc no acepta identidad.' >&2; exit 2; }
        ;;
    distribution)
        [ -n "$IDENTITY" ] || { printf '%s\n' 'ERROR: distribution requiere Developer ID Application.' >&2; exit 2; }
        case "$IDENTITY" in
            'Developer ID Application: '*) ;;
            *) printf '%s\n' 'ERROR: la identidad no es Developer ID Application.' >&2; exit 2 ;;
        esac
        ;;
    *) printf 'ERROR: modo desconocido: %s\n' "$MODE" >&2; exit 2 ;;
esac

case "$OUTPUT_DMG" in *.dmg) ;; *) printf '%s\n' 'ERROR: la salida debe terminar en .dmg.' >&2; exit 2 ;; esac
[ ! -e "$OUTPUT_DMG" ] && [ ! -L "$OUTPUT_DMG" ] || {
    printf 'ERROR: la salida ya existe; no se reemplaza: %s\n' "$OUTPUT_DMG" >&2
    exit 1
}

"$SCRIPT_DIR/verify-release.sh" "$APP" "$MODE"

DMG_ROOT=$(/usr/bin/mktemp -d "/private/tmp/TidyDropDMG.create.XXXXXX")
trap '/bin/rm -rf "$DMG_ROOT"' EXIT HUP INT TERM
STAGING="$DMG_ROOT/staging"
/bin/mkdir -p "$STAGING"
/usr/bin/ditto "$APP" "$STAGING/TidyDrop.app"
/bin/ln -s /Applications "$STAGING/Applications"

/bin/mkdir -p "$(dirname -- "$OUTPUT_DMG")"
/usr/bin/hdiutil create \
    -volname 'TidyDrop' \
    -srcfolder "$STAGING" \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$OUTPUT_DMG" >/dev/null

if [ "$MODE" = 'distribution' ]; then
    /usr/bin/codesign --force --sign "$IDENTITY" --timestamp "$OUTPUT_DMG"
    /usr/bin/codesign --verify --strict --verbose=2 "$OUTPUT_DMG"
fi

VERIFY_MODE=$MODE
[ "$MODE" = 'distribution' ] && VERIFY_MODE=distribution-pre-notary
"$SCRIPT_DIR/verify-dmg.sh" "$OUTPUT_DMG" "$VERIFY_MODE"
printf 'DMG creado y verificado: %s\n' "$OUTPUT_DMG"
