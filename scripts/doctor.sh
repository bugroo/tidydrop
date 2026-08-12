#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
XCRUN_BIN=${TIDYDROP_XCRUN_BIN:-/usr/bin/xcrun}
failures=0

ok() { printf '%-64s %s\n' "$1" '[OK]'; }
fail() { printf '%-64s %s\n' "$1" '[FALLO]'; failures=$((failures + 1)); }

printf '%s\n' 'TidyDrop — inspección previa de macOS'

if [ "$(uname -s)" = "Darwin" ]; then
    ok 'Sistema operativo macOS'
else
    fail "Sistema operativo macOS (detectado: $(uname -s))"
fi

if command -v sw_vers >/dev/null 2>&1; then
    sw_vers
    product_version=$(sw_vers -productVersion)
    major_version=$(printf '%s' "$product_version" | /usr/bin/cut -d. -f1)
    case "$major_version" in
        ''|*[!0-9]*) fail "Versión de macOS interpretable (detectada: $product_version)" ;;
        *)
            if [ "$major_version" -ge 13 ]; then
                ok "macOS 13 o posterior (detectado: $product_version)"
            else
                fail "macOS 13 o posterior (detectado: $product_version)"
            fi
            ;;
    esac
fi
printf 'Arquitectura: %s\n' "$(uname -m)"

for utility in /usr/bin/file /usr/bin/plutil /bin/launchctl /usr/bin/codesign "$XCRUN_BIN" /usr/bin/xcode-select; do
    if [ -x "$utility" ]; then
        ok "Utilidad $utility"
    else
        fail "Utilidad $utility"
    fi
done

if /usr/bin/xcode-select -p >/dev/null 2>&1; then
    developer_dir=$(/usr/bin/xcode-select -p)
    ok "Developer directory: $developer_dir"
else
    fail 'Apple Command Line Tools'
    printf '%s\n' '  Instálalas sin Xcode completo mediante: xcode-select --install'
fi

swift_path=''
swiftc_path=''
sdk_path=''
sdk_version=''
if "$XCRUN_BIN" --sdk macosx --find swift >/dev/null 2>&1 \
   && "$XCRUN_BIN" --sdk macosx --find swiftc >/dev/null 2>&1; then
    swift_path=$("$XCRUN_BIN" --sdk macosx --find swift)
    swiftc_path=$("$XCRUN_BIN" --sdk macosx --find swiftc)
    ok "Swift Package Manager: $swift_path"
    ok "Compilador Swift: $swiftc_path"
    "$swift_path" --version | /usr/bin/sed -n '1,2p'
else
    fail 'Swift y swiftc disponibles mediante xcrun'
fi

if sdk_path=$("$XCRUN_BIN" --sdk macosx --show-sdk-path 2>/dev/null) \
   && [ -d "$sdk_path" ]; then
    ok "SDK macOS: $sdk_path"
else
    sdk_path=''
    fail 'SDK macOS disponible mediante xcrun'
fi
if sdk_version=$("$XCRUN_BIN" --sdk macosx --show-sdk-version 2>/dev/null) \
   && [ -n "$sdk_version" ]; then
    ok "Versión SDK macOS: $sdk_version"
else
    sdk_version=''
    fail 'Versión del SDK macOS'
fi

if /usr/bin/grep -RInE '(^|[[:space:]])import[[:space:]]+XCTest|\.testTarget[[:space:]]*\(' \
    "$PROJECT_ROOT/Package.swift" "$PROJECT_ROOT/Sources" "$PROJECT_ROOT/SelfTests" >/dev/null 2>&1; then
    fail 'Proyecto sin dependencia de XCTest'
else
    ok 'Proyecto sin XCTest; Xcode completo no es necesario'
fi

PROBE_DIR=$(mktemp -d "/private/tmp/TidyDropIntegration.doctor.XXXXXX")
trap '/bin/rm -rf "$PROBE_DIR"' EXIT HUP INT TERM
if [ -n "$swiftc_path" ] && [ -n "$sdk_path" ]; then
    cat > "$PROBE_DIR/FoundationProbe.swift" <<'SWIFT'
import Foundation
let value = URL(fileURLWithPath: "/tmp").standardizedFileURL.path
print(value)
SWIFT
    printf 'Comando probe: SDKROOT=<SDK> swiftc -sdk <SDK> -warnings-as-errors FoundationProbe.swift\n'
    if SDKROOT="$sdk_path" "$swiftc_path" -sdk "$sdk_path" -warnings-as-errors \
        "$PROBE_DIR/FoundationProbe.swift" -o "$PROBE_DIR/foundation-probe"; then
        ok 'Compilación Swift/Foundation con SDK explícito'
    else
        fail 'Compilación Swift/Foundation con Command Line Tools'
    fi
    if [ -x "$PROBE_DIR/foundation-probe" ] \
       && [ "$("$PROBE_DIR/foundation-probe")" = '/tmp' ]; then
        ok 'Ejecución del probe Swift/Foundation'
    else
        fail 'Ejecución del probe Swift/Foundation'
    fi
fi

if [ -n "$swift_path" ]; then
    if "$swift_path" package --package-path "$PROJECT_ROOT" describe >/dev/null 2>&1; then
        ok 'Swift Package Manager puede interpretar el proyecto'
    else
        fail 'Swift Package Manager puede interpretar el proyecto'
    fi
fi

if [ -d "$HOME/Downloads" ]; then
    ok "Carpeta $HOME/Downloads"
    if /bin/ls -1A "$HOME/Downloads" >/dev/null 2>&1; then
        ok 'Lectura de Downloads desde el proceso de instalación'
    else
        fail 'Lectura de Downloads desde el proceso de instalación (TCC/permisos)'
    fi
else
    fail "Carpeta $HOME/Downloads"
fi

printf 'TidyDrop MIME probe\n' > "$PROBE_DIR/mime-probe.txt"
if mime=$(/usr/bin/file --brief --mime-type -- "$PROBE_DIR/mime-probe.txt" 2>/dev/null) && [ -n "$mime" ]; then
    ok "Detección MIME nativa: $mime"
else
    fail 'Detección MIME con /usr/bin/file'
fi

if [ "$failures" -ne 0 ]; then
    printf '\nResultado: %s fallo(s). No se ha instalado ni activado nada.\n' "$failures"
    exit 1
fi

printf '\nResultado: entorno apto sin Xcode completo ni XCTest. No se ha instalado ni activado nada.\n'
