#!/bin/sh
set -eu

umask 077

if [ "$#" -ne 3 ]; then
    printf 'Uso: %s APP DIRECTORIO_SALIDA (development|distribution)\n' "$0" >&2
    exit 2
fi

APP=$1
OUTPUT_DIR=$2
MODE=$3
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
VERSION=$(/bin/cat "$PROJECT_ROOT/VERSION")

case "$MODE" in
    development)
        BASENAME="TidyDrop-$VERSION-macos-universal-development"
        ;;
    distribution)
        BASENAME="TidyDrop-$VERSION-macos-universal"
        ;;
    *)
        printf 'ERROR: modo desconocido: %s\n' "$MODE" >&2
        exit 2
        ;;
esac

"$SCRIPT_DIR/verify-release.sh" "$APP" "$MODE"

[ ! -L "$OUTPUT_DIR" ] || {
    printf 'ERROR: el directorio de salida no puede ser un symlink: %s\n' "$OUTPUT_DIR" >&2
    exit 1
}
/bin/mkdir -p "$OUTPUT_DIR"
[ -d "$OUTPUT_DIR" ] && [ ! -L "$OUTPUT_DIR" ] || {
    printf 'ERROR: directorio de salida ausente o inseguro: %s\n' "$OUTPUT_DIR" >&2
    exit 1
}
ZIP="$OUTPUT_DIR/$BASENAME.zip"
CHECKSUM="$OUTPUT_DIR/$BASENAME.sha256"
if [ -e "$ZIP" ] || [ -L "$ZIP" ] || [ -e "$CHECKSUM" ] || [ -L "$CHECKSUM" ]; then
    printf '%s\n' 'ERROR: los artefactos de salida ya existen; no se reemplazan.' >&2
    exit 1
fi

/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
(
    cd "$OUTPUT_DIR"
    /usr/bin/shasum -a 256 "$(basename -- "$ZIP")" >"$(basename -- "$CHECKSUM")"
)

ENTRY_LIST="$OUTPUT_DIR/.$BASENAME.entries.$$"
trap '/bin/rm -f "$ENTRY_LIST"' EXIT HUP INT TERM
/usr/bin/unzip -Z1 "$ZIP" >"$ENTRY_LIST"
if /usr/bin/awk '
    /^\// { bad=1 }
    /(^|\/)\.\.($|\/)/ { bad=1 }
    END { exit bad ? 0 : 1 }
' "$ENTRY_LIST"; then
    printf '%s\n' 'ERROR: el ZIP contiene una ruta absoluta o traversal.' >&2
    exit 1
fi

VERIFY_ROOT=$(/usr/bin/mktemp -d "/private/tmp/TidyDropRelease.extract.XXXXXX")
trap '/bin/rm -f "$ENTRY_LIST"; /bin/rm -rf "$VERIFY_ROOT"' EXIT HUP INT TERM
/usr/bin/ditto -x -k "$ZIP" "$VERIFY_ROOT"
"$SCRIPT_DIR/verify-release.sh" "$VERIFY_ROOT/TidyDrop.app" "$MODE"
(
    cd "$OUTPUT_DIR"
    /usr/bin/shasum -a 256 -c "$(basename -- "$CHECKSUM")"
)

printf 'Artefacto: %s\nChecksum: %s\n' "$ZIP" "$CHECKSUM"
