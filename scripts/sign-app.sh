#!/bin/sh
set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    printf 'Uso: %s APP (--adhoc | --developer-id IDENTIDAD)\n' "$0" >&2
    exit 2
fi

APP=$1
MODE=$2
IDENTITY=${3:-}

[ -d "$APP" ] && [ ! -L "$APP" ] || {
    printf 'ERROR: bundle ausente o inseguro: %s\n' "$APP" >&2
    exit 1
}
[ -x "$APP/Contents/MacOS/tidydrop" ] || {
    printf '%s\n' 'ERROR: falta el ejecutable principal.' >&2
    exit 1
}

case "$MODE" in
    --adhoc)
        [ -z "$IDENTITY" ] || {
            printf '%s\n' 'ERROR: --adhoc no acepta identidad.' >&2
            exit 2
        }
        /usr/bin/codesign --force --sign - --options runtime --timestamp=none "$APP"
        ;;
    --developer-id)
        [ -n "$IDENTITY" ] || {
            printf '%s\n' 'ERROR: falta la identidad Developer ID Application.' >&2
            exit 2
        }
        /usr/bin/codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
        ;;
    *)
        printf 'ERROR: modo de firma desconocido: %s\n' "$MODE" >&2
        exit 2
        ;;
esac

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
SIGNATURE_INFO=$(/usr/bin/codesign --display --verbose=4 "$APP" 2>&1)
printf '%s\n' "$SIGNATURE_INFO" | /usr/bin/grep -E 'flags=.*runtime' >/dev/null || {
    printf '%s\n' 'ERROR: la firma no habilitó Hardened Runtime.' >&2
    exit 1
}
if [ "$MODE" = '--developer-id' ]; then
    printf '%s\n' "$SIGNATURE_INFO" | /usr/bin/grep -q '^Authority=Developer ID Application:' || {
        printf '%s\n' 'ERROR: la identidad aplicada no es Developer ID Application.' >&2
        exit 1
    }
    printf '%s\n' "$SIGNATURE_INFO" | /usr/bin/grep -q '^Timestamp=' || {
        printf '%s\n' 'ERROR: falta el timestamp seguro de Developer ID.' >&2
        exit 1
    }
fi
printf 'Firma aplicada y verificada: %s\n' "$MODE"
