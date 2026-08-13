#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    printf 'Uso: %s APP (development|distribution)\n' "$0" >&2
    exit 2
fi

APP=$1
MODE=$2
EXECUTABLE="$APP/Contents/MacOS/tidydrop"
INFO_PLIST="$APP/Contents/Info.plist"

case "$MODE" in
    development|distribution) ;;
    *) printf 'ERROR: modo desconocido: %s\n' "$MODE" >&2; exit 2 ;;
esac

[ -d "$APP" ] && [ ! -L "$APP" ] || {
    printf 'ERROR: bundle ausente o symlink: %s\n' "$APP" >&2
    exit 1
}
[ -x "$EXECUTABLE" ] && [ -f "$INFO_PLIST" ] && [ ! -L "$EXECUTABLE" ] && [ ! -L "$INFO_PLIST" ] || {
    printf '%s\n' 'ERROR: bundle incompleto o con entradas inseguras.' >&2
    exit 1
}

if /usr/bin/find "$APP" -type l -print | /usr/bin/grep . >/dev/null 2>&1; then
    printf '%s\n' 'ERROR: el bundle simple de TidyDrop no debe contener symlinks.' >&2
    exit 1
fi
if /usr/bin/find "$APP" -name '.DS_Store' -print | /usr/bin/grep . >/dev/null 2>&1; then
    printf '%s\n' 'ERROR: el bundle contiene .DS_Store.' >&2
    exit 1
fi

/usr/bin/plutil -lint "$INFO_PLIST"
BUNDLE_ID=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$INFO_PLIST")
BUNDLE_VERSION=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")
MINIMUM_SYSTEM=$(/usr/bin/plutil -extract LSMinimumSystemVersion raw -o - "$INFO_PLIST")
[ "$BUNDLE_VERSION" = "$(/bin/cat "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/VERSION")" ] || {
    printf '%s\n' 'ERROR: la versión del bundle no coincide con VERSION.' >&2
    exit 1
}
[ "$MINIMUM_SYSTEM" = '13.0' ] || {
    printf 'ERROR: versión mínima inesperada: %s\n' "$MINIMUM_SYSTEM" >&2
    exit 1
}

ARCHS=$(/usr/bin/lipo -archs "$EXECUTABLE")
case " $ARCHS " in *' arm64 '*) ;; *) printf '%s\n' 'ERROR: falta arm64.' >&2; exit 1 ;; esac
case " $ARCHS " in *' x86_64 '*) ;; *) printf '%s\n' 'ERROR: falta x86_64.' >&2; exit 1 ;; esac
[ "$(printf '%s\n' "$ARCHS" | /usr/bin/wc -w | /usr/bin/tr -d ' ')" -eq 2 ] || {
    printf 'ERROR: arquitecturas inesperadas: %s\n' "$ARCHS" >&2
    exit 1
}

for release_arch in arm64 x86_64; do
    COMPILED_MINIMUM=$(/usr/bin/otool -arch "$release_arch" -l "$EXECUTABLE" \
        | /usr/bin/awk '/cmd LC_BUILD_VERSION/ { in_build=1; next } in_build && /^[[:space:]]*minos / { print $2; exit }')
    [ "$COMPILED_MINIMUM" = '13.0' ] || {
        printf 'ERROR: minos de %s es %s; se esperaba 13.0.\n' "$release_arch" "$COMPILED_MINIMUM" >&2
        exit 1
    }
done

if /usr/bin/otool -L "$EXECUTABLE" \
    | /usr/bin/grep -E '/Library/Developer/|/Applications/Xcode[^/]*\.app/' >/dev/null 2>&1; then
    printf '%s\n' 'ERROR: dependencia del toolchain de desarrollo detectada.' >&2
    exit 1
fi
if /usr/bin/otool -l "$EXECUTABLE" \
    | /usr/bin/grep -E '/Library/Developer/|/Applications/Xcode[^/]*\.app/' >/dev/null 2>&1; then
    printf '%s\n' 'ERROR: rpath del toolchain de desarrollo detectado.' >&2
    exit 1
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
SIGNATURE_INFO=$(/usr/bin/codesign --display --verbose=4 "$APP" 2>&1)
printf '%s\n' "$SIGNATURE_INFO" | /usr/bin/grep -E 'flags=.*runtime' >/dev/null || {
    printf '%s\n' 'ERROR: Hardened Runtime ausente.' >&2
    exit 1
}
ENTITLEMENTS=$(/usr/bin/codesign --display --entitlements - "$APP" 2>&1 || true)
if printf '%s\n' "$ENTITLEMENTS" | /usr/bin/grep -q 'com.apple.security.get-task-allow'; then
    printf '%s\n' 'ERROR: get-task-allow no puede distribuirse.' >&2
    exit 1
fi

if [ "$MODE" = 'distribution' ]; then
    EXPECTED_BUNDLE_ID=${TIDYDROP_RELEASE_BUNDLE_ID:-}
    EXPECTED_TEAM_ID=${TIDYDROP_RELEASE_TEAM_ID:-}
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
    [ "$BUNDLE_ID" = "$EXPECTED_BUNDLE_ID" ] || {
        printf 'ERROR: bundle ID %s; se esperaba %s.\n' "$BUNDLE_ID" "$EXPECTED_BUNDLE_ID" >&2
        exit 1
    }
    printf '%s\n' "$SIGNATURE_INFO" | /usr/bin/grep -q '^Authority=Developer ID Application:' || {
        printf '%s\n' 'ERROR: la firma no es Developer ID Application.' >&2
        exit 1
    }
    ACTUAL_TEAM_ID=$(printf '%s\n' "$SIGNATURE_INFO" \
        | /usr/bin/awk -F= '$1 == "TeamIdentifier" { print substr($0, index($0, "=") + 1); exit }')
    [ "$ACTUAL_TEAM_ID" = "$EXPECTED_TEAM_ID" ] || {
        printf '%s\n' 'ERROR: Team ID inesperado.' >&2
        exit 1
    }
    printf '%s\n' "$SIGNATURE_INFO" | /usr/bin/grep -q '^Timestamp=' || {
        printf '%s\n' 'ERROR: falta timestamp seguro.' >&2
        exit 1
    }
    /usr/sbin/spctl --assess --type execute --verbose=4 "$APP"
    /usr/bin/xcrun stapler validate "$APP"
fi

printf 'Release verification: PASS mode=%s bundle=%s archs=%s\n' "$MODE" "$BUNDLE_ID" "$ARCHS"
