#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

printf '%s\n' 'TidyDrop — auditoría estática local'

for script in "$PROJECT_ROOT"/scripts/*.sh; do
    /bin/sh -n "$script"
done
printf '%s\n' '[OK] Sintaxis POSIX sh'

if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$PROJECT_ROOT/app/Info.plist"
    plutil -lint "$PROJECT_ROOT/launchd/com.local.tidydrop.plist.example"
    printf '%s\n' '[OK] Plists válidos'
else
    printf '%s\n' '[AVISO] plutil no disponible; se omite lint de plists.'
fi

if /usr/bin/grep -RInE 'URLSession|NWConnection|Network\.framework|CFNetwork|socket\(' \
    "$PROJECT_ROOT/Sources" >/dev/null 2>&1; then
    printf '%s\n' '[FALLO] Se detectó una API de red en Sources.' >&2
    /usr/bin/grep -RInE 'URLSession|NWConnection|Network\.framework|CFNetwork|socket\(' \
        "$PROJECT_ROOT/Sources" >&2 || true
    exit 1
fi
printf '%s\n' '[OK] Sin APIs de red detectadas en Sources'

if /usr/bin/grep -RInE '^[[:space:]]*(curl|wget|nc|ncat|ssh|scp|sftp)[[:space:]]' \
    "$PROJECT_ROOT/scripts" >/dev/null 2>&1; then
    printf '%s\n' '[FALLO] Se detectó una utilidad de red ejecutada por un script.' >&2
    exit 1
fi
printf '%s\n' '[OK] Sin utilidades de red ejecutadas por scripts'

unexpected_removals=$(
    /usr/bin/grep -RIn 'removeItem' "$PROJECT_ROOT/Sources" 2>/dev/null \
        | /usr/bin/grep -v '/FileSystem.swift:' \
        | /usr/bin/grep -v '/Transactions.swift:' \
        || true
)
if [ -n "$unexpected_removals" ]; then
    printf '%s\n' '[FALLO] Se detectó removeItem fuera de la retención controlada.' >&2
    printf '%s\n' "$unexpected_removals" >&2
    exit 1
fi
if ! /usr/bin/grep -q 'APP_OWNED_RETENTION' "$PROJECT_ROOT/Sources/TidyDropCore/FileSystem.swift" \
   || ! /usr/bin/grep -q 'APP_OWNED_RETENTION' "$PROJECT_ROOT/Sources/TidyDropCore/Transactions.swift"; then
    printf '%s\n' '[FALLO] Las eliminaciones de retención no están etiquetadas y acotadas.' >&2
    exit 1
fi
if /usr/bin/grep -n 'removeItem' "$PROJECT_ROOT/Sources/TidyDropCore/StewardEngine.swift" >/dev/null 2>&1; then
    printf '%s\n' '[FALLO] El motor de organización no debe borrar archivos.' >&2
    exit 1
fi
printf '%s\n' '[OK] Sin borrado en la carpeta activa; solo retención de logs/manifiestos propios'

if /usr/bin/grep -RInE '^[[:space:]]*sudo[[:space:]]' "$PROJECT_ROOT/scripts" >/dev/null 2>&1; then
    printf '%s\n' '[FALLO] Se detectó una ejecución de sudo.' >&2
    exit 1
fi
printf '%s\n' '[OK] Sin ejecución de sudo'

if /usr/bin/grep -nE '\.package[[:space:]]*\(' "$PROJECT_ROOT/Package.swift" >/dev/null 2>&1; then
    printf '%s\n' '[FALLO] Package.swift declara dependencias externas.' >&2
    exit 1
fi
printf '%s\n' '[OK] Swift Package sin dependencias externas declaradas'

if /usr/bin/grep -RInE '(^|[[:space:]])import[[:space:]]+XCTest|\.testTarget[[:space:]]*\(' \
    "$PROJECT_ROOT/Package.swift" "$PROJECT_ROOT/Sources" "$PROJECT_ROOT/SelfTests" >/dev/null 2>&1; then
    printf '%s\n' '[FALLO] Se detectó una dependencia de XCTest.' >&2
    exit 1
fi
printf '%s\n' '[OK] Self-tests ejecutables sin XCTest ni Xcode completo'

if /usr/bin/grep -RInE 'StandardOutPath|StandardErrorPath' \
    "$PROJECT_ROOT/launchd" "$PROJECT_ROOT/scripts/render-launchagent.sh" >/dev/null 2>&1; then
    printf '%s\n' '[FALLO] El LaunchAgent no debe crear stdout/stderr ilimitados.' >&2
    exit 1
fi
printf '%s\n' '[OK] LaunchAgent sin logs stdout/stderr ilimitados'

printf '%s\n' 'Auditoría estática: PASS'
