#!/bin/sh
set -eu

umask 077

if [ "$#" -ne 2 ]; then
    printf 'Uso: %s APP_SALIDA BUNDLE_ID\n' "$0" >&2
    exit 2
fi

OUTPUT_APP=$1
BUNDLE_ID=$2
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
INFO_PLIST_SOURCE="$PROJECT_ROOT/app/Distribution-Info.plist"
AGENT_PLIST_SOURCE="$PROJECT_ROOT/app/io.github.bugroo.tidydrop.agent.plist"
DEPLOYMENT_TARGET='13.0'

if [ "$(uname -s)" != 'Darwin' ]; then
    printf '%s\n' 'ERROR: el build Universal 2 requiere macOS.' >&2
    exit 1
fi

case "$BUNDLE_ID" in
    ''|.*|*..*|*[!A-Za-z0-9.-]*|*.)
        printf 'ERROR: bundle ID inválido: %s\n' "$BUNDLE_ID" >&2
        exit 2
        ;;
esac
if [ "$BUNDLE_ID" != 'io.github.bugroo.tidydrop' ]; then
    printf 'ERROR: bundle ID de distribución inesperado: %s\n' "$BUNDLE_ID" >&2
    exit 2
fi
case "$BUNDLE_ID" in
    *.*) ;;
    *) printf 'ERROR: el bundle ID debe tener al menos dos componentes: %s\n' "$BUNDLE_ID" >&2; exit 2 ;;
esac

case "$OUTPUT_APP" in
    *.app) ;;
    *)
        printf '%s\n' 'ERROR: APP_SALIDA debe terminar en .app.' >&2
        exit 2
        ;;
esac

if [ -e "$OUTPUT_APP" ] || [ -L "$OUTPUT_APP" ]; then
    printf 'ERROR: la salida ya existe; no se reemplaza: %s\n' "$OUTPUT_APP" >&2
    exit 1
fi

SDK_PATH=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
[ -d "$SDK_PATH" ] || {
    printf 'ERROR: SDK macOS inválido: %s\n' "$SDK_PATH" >&2
    exit 1
}

LIPO=$(/usr/bin/xcrun --find lipo)
INSTALL_NAME_TOOL=$(/usr/bin/xcrun --find install_name_tool)
[ -x "$LIPO" ] && [ -x "$INSTALL_NAME_TOOL" ] || {
    printf '%s\n' 'ERROR: faltan lipo o install_name_tool.' >&2
    exit 1
}

BUILD_ROOT=$(/usr/bin/mktemp -d "/private/tmp/TidyDropUniversal.build.XXXXXX")
trap '/bin/rm -rf "$BUILD_ROOT"' EXIT HUP INT TERM
ARM_SCRATCH="$BUILD_ROOT/arm64"
X86_SCRATCH="$BUILD_ROOT/x86_64"
STAGING_APP="$BUILD_ROOT/TidyDrop.app"

printf '%s\n' '[1/5] Compilando arm64 con advertencias como errores...'
SDKROOT="$SDK_PATH" /usr/bin/xcrun swift build \
    --package-path "$PROJECT_ROOT" \
    --scratch-path "$ARM_SCRATCH" \
    --configuration release \
    --triple "arm64-apple-macosx$DEPLOYMENT_TARGET" \
    -Xswiftc -warnings-as-errors
ARM_BIN_DIR=$(SDKROOT="$SDK_PATH" /usr/bin/xcrun swift build \
    --package-path "$PROJECT_ROOT" \
    --scratch-path "$ARM_SCRATCH" \
    --configuration release \
    --triple "arm64-apple-macosx$DEPLOYMENT_TARGET" \
    --show-bin-path)

printf '%s\n' '[2/5] Compilando x86_64 con advertencias como errores...'
SDKROOT="$SDK_PATH" /usr/bin/xcrun swift build \
    --package-path "$PROJECT_ROOT" \
    --scratch-path "$X86_SCRATCH" \
    --configuration release \
    --triple "x86_64-apple-macosx$DEPLOYMENT_TARGET" \
    -Xswiftc -warnings-as-errors
X86_BIN_DIR=$(SDKROOT="$SDK_PATH" /usr/bin/xcrun swift build \
    --package-path "$PROJECT_ROOT" \
    --scratch-path "$X86_SCRATCH" \
    --configuration release \
    --triple "x86_64-apple-macosx$DEPLOYMENT_TARGET" \
    --show-bin-path)

ARM_APP="$ARM_BIN_DIR/TidyDropApp"
X86_APP="$X86_BIN_DIR/TidyDropApp"
ARM_CLI="$ARM_BIN_DIR/tidydrop"
X86_CLI="$X86_BIN_DIR/tidydrop"
ARM_AGENT="$ARM_BIN_DIR/tidydrop-agent"
X86_AGENT="$X86_BIN_DIR/tidydrop-agent"
ARM_SELF_TEST="$ARM_BIN_DIR/tidydrop-self-test"
X86_SELF_TEST="$X86_BIN_DIR/tidydrop-self-test"
[ -x "$ARM_APP" ] && [ -x "$X86_APP" ] \
    && [ -x "$ARM_CLI" ] && [ -x "$X86_CLI" ] \
    && [ -x "$ARM_AGENT" ] && [ -x "$X86_AGENT" ] \
    && [ -x "$ARM_SELF_TEST" ] && [ -x "$X86_SELF_TEST" ] || {
    printf '%s\n' 'ERROR: SwiftPM no produjo todos los binarios esperados.' >&2
    exit 1
}

printf '%s\n' '[3/5] Ejecutando self-tests nativos antes de ensamblar...'
case "$(uname -m)" in
    arm64) "$ARM_SELF_TEST" ;;
    x86_64) "$X86_SELF_TEST" ;;
    *) printf '%s\n' 'ERROR: arquitectura host no soportada para ejecutar self-tests.' >&2; exit 1 ;;
esac

printf '%s\n' '[4/5] Ensamblando bundle Universal 2...'
/bin/mkdir -p \
    "$STAGING_APP/Contents/MacOS" \
    "$STAGING_APP/Contents/Resources" \
    "$STAGING_APP/Contents/Library/LaunchAgents"
/bin/cp "$INFO_PLIST_SOURCE" "$STAGING_APP/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$STAGING_APP/Contents/Info.plist"
/bin/cp "$AGENT_PLIST_SOURCE" \
    "$STAGING_APP/Contents/Library/LaunchAgents/io.github.bugroo.tidydrop.agent.plist"

remove_developer_rpaths() {
    thin_binary=$1
    rpath_list=$2
    /usr/bin/otool -l "$thin_binary" | /usr/bin/awk '
        /cmd LC_RPATH/ { in_rpath=1; next }
        in_rpath && /^[[:space:]]*path / {
            line=$0
            sub(/^[[:space:]]*path /, "", line)
            sub(/ \(offset [0-9]+\)$/, "", line)
            if (line ~ "^/Library/Developer/" || line ~ "^/Applications/Xcode") print line
            in_rpath=0
        }
    ' >"$rpath_list"
    while IFS= read -r developer_rpath; do
        [ -n "$developer_rpath" ] || continue
        "$INSTALL_NAME_TOOL" -delete_rpath "$developer_rpath" "$thin_binary"
    done <"$rpath_list"
}

# install_name_tool elimina rpaths de forma fiable en cada slice fino; después
# lipo compone el ejecutable final. Así nunca se firma ni distribuye una ruta
# que dependa del toolchain de la máquina de build.
assemble_binary() {
    binary_name=$1
    arm_source=$2
    x86_source=$3
    destination=$4
    sanitized_arm="$BUILD_ROOT/$binary_name-arm64"
    sanitized_x86="$BUILD_ROOT/$binary_name-x86_64"
    /bin/cp "$arm_source" "$sanitized_arm"
    /bin/cp "$x86_source" "$sanitized_x86"
    remove_developer_rpaths "$sanitized_arm" "$BUILD_ROOT/$binary_name-arm64-rpaths.txt"
    remove_developer_rpaths "$sanitized_x86" "$BUILD_ROOT/$binary_name-x86_64-rpaths.txt"
    "$LIPO" -create "$sanitized_arm" "$sanitized_x86" -output "$destination"
    /bin/chmod 755 "$destination"
}

assemble_binary app "$ARM_APP" "$X86_APP" "$STAGING_APP/Contents/MacOS/TidyDropApp"
assemble_binary cli "$ARM_CLI" "$X86_CLI" "$STAGING_APP/Contents/Resources/tidydrop"
assemble_binary agent "$ARM_AGENT" "$X86_AGENT" "$STAGING_APP/Contents/Resources/tidydrop-agent"
/bin/chmod 644 "$STAGING_APP/Contents/Info.plist"
/bin/chmod 644 "$STAGING_APP/Contents/Library/LaunchAgents/io.github.bugroo.tidydrop.agent.plist"

printf '%s\n' '[5/5] Verificando arquitectura, versión mínima y dependencias...'
for bundled_binary in \
    "$STAGING_APP/Contents/MacOS/TidyDropApp" \
    "$STAGING_APP/Contents/Resources/tidydrop" \
    "$STAGING_APP/Contents/Resources/tidydrop-agent"; do
    ARCHS=$("$LIPO" -archs "$bundled_binary")
    case " $ARCHS " in *' arm64 '*) ;; *) printf 'ERROR: falta arm64 en %s.\n' "$bundled_binary" >&2; exit 1 ;; esac
    case " $ARCHS " in *' x86_64 '*) ;; *) printf 'ERROR: falta x86_64 en %s.\n' "$bundled_binary" >&2; exit 1 ;; esac
    [ "$(printf '%s\n' "$ARCHS" | /usr/bin/wc -w | /usr/bin/tr -d ' ')" -eq 2 ] || {
        printf 'ERROR: arquitecturas inesperadas en %s: %s\n' "$bundled_binary" "$ARCHS" >&2
        exit 1
    }
    if /usr/bin/otool -L "$bundled_binary" \
        | /usr/bin/grep -E '/Library/Developer/|/Applications/Xcode[^/]*\.app/' >/dev/null 2>&1; then
        printf 'ERROR: %s depende del toolchain de desarrollo.\n' "$bundled_binary" >&2
        exit 1
    fi
done

/usr/bin/plutil -lint "$STAGING_APP/Contents/Info.plist"
[ "$(/usr/bin/plutil -extract LSMinimumSystemVersion raw -o - "$STAGING_APP/Contents/Info.plist")" = "$DEPLOYMENT_TARGET" ] || {
    printf '%s\n' 'ERROR: LSMinimumSystemVersion no coincide con el deployment target.' >&2
    exit 1
}

/bin/mkdir -p "$(dirname -- "$OUTPUT_APP")"
/usr/bin/plutil -lint "$STAGING_APP/Contents/Library/LaunchAgents/io.github.bugroo.tidydrop.agent.plist"
[ "$(/usr/bin/plutil -extract BundleProgram raw -o - "$STAGING_APP/Contents/Library/LaunchAgents/io.github.bugroo.tidydrop.agent.plist")" = 'Contents/Resources/tidydrop-agent' ] || {
    printf '%s\n' 'ERROR: BundleProgram del agente es inesperado.' >&2
    exit 1
}

/bin/mv "$STAGING_APP" "$OUTPUT_APP"
printf 'Universal app preparada: %s (arm64 x86_64; app + CLI + agent)\n' "$OUTPUT_APP"
