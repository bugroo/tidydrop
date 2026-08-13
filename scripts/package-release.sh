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
DMG="$OUTPUT_DIR/$BASENAME.dmg"
CHECKSUM="$OUTPUT_DIR/$BASENAME.sha256"
if [ -e "$DMG" ] || [ -L "$DMG" ] || [ -e "$CHECKSUM" ] || [ -L "$CHECKSUM" ]; then
    printf '%s\n' 'ERROR: los artefactos de salida ya existen; no se reemplazan.' >&2
    exit 1
fi

if [ "$MODE" = 'distribution' ]; then
    SIGNING_IDENTITY=${TIDYDROP_RELEASE_SIGNING_IDENTITY:-}
    NOTARY_PROFILE=${TIDYDROP_NOTARY_PROFILE:-}
    [ -n "$SIGNING_IDENTITY" ] && [ -n "$NOTARY_PROFILE" ] || {
        printf '%s\n' 'ERROR: distribution requiere TIDYDROP_RELEASE_SIGNING_IDENTITY y TIDYDROP_NOTARY_PROFILE.' >&2
        exit 1
    }
    "$SCRIPT_DIR/create-dmg.sh" "$APP" "$DMG" distribution "$SIGNING_IDENTITY"
    "$SCRIPT_DIR/notarize-dmg.sh" "$DMG" --keychain-profile "$NOTARY_PROFILE"
else
    "$SCRIPT_DIR/create-dmg.sh" "$APP" "$DMG" development
fi

(
    cd "$OUTPUT_DIR"
    /usr/bin/shasum -a 256 "$(basename -- "$DMG")" >"$(basename -- "$CHECKSUM")"
)
"$SCRIPT_DIR/verify-dmg.sh" "$DMG" "$MODE"
(
    cd "$OUTPUT_DIR"
    /usr/bin/shasum -a 256 -c "$(basename -- "$CHECKSUM")"
)

printf 'Artefacto: %s\nChecksum: %s\n' "$DMG" "$CHECKSUM"
