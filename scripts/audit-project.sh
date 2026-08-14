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
    plutil -lint "$PROJECT_ROOT/app/Distribution-Info.plist"
    plutil -lint "$PROJECT_ROOT/app/io.github.bugroo.tidydrop.agent.plist"
    plutil -lint "$PROJECT_ROOT/app/io.github.bugroo.tidydrop.agent.community.v5.plist"
    plutil -lint "$PROJECT_ROOT/app/io.github.bugroo.tidydrop.agent.community.v6.plist"
    plutil -lint "$PROJECT_ROOT/app/io.github.bugroo.tidydrop.agent.community.v7.plist"
    plutil -lint "$PROJECT_ROOT/app/TidyDrop.entitlements"
    plutil -lint "$PROJECT_ROOT/app/TidyDropAgent.entitlements"
    plutil -lint "$PROJECT_ROOT/launchd/com.local.tidydrop.plist.example"
    PRODUCT_VERSION=$(/bin/cat "$PROJECT_ROOT/VERSION")
    [ "$(plutil -extract CFBundleShortVersionString raw -o - "$PROJECT_ROOT/app/Info.plist")" = "$PRODUCT_VERSION" ] \
        && [ "$(plutil -extract CFBundleShortVersionString raw -o - "$PROJECT_ROOT/app/Distribution-Info.plist")" = "$PRODUCT_VERSION" ] \
        && /usr/bin/grep -Fq "private let programVersion = \"$PRODUCT_VERSION\"" "$PROJECT_ROOT/Sources/TidyDrop/main.swift" \
        && /usr/bin/grep -Fq "static let version = \"$PRODUCT_VERSION\"" "$PROJECT_ROOT/Sources/TidyDropApp/TidyDropApplication.swift" || {
        printf '%s\n' '[FALLO] VERSION, plists, CLI y app no comparten la misma versión.' >&2
        exit 1
    }
    [ "$(plutil -extract Label raw -o - "$PROJECT_ROOT/app/io.github.bugroo.tidydrop.agent.community.v7.plist")" = 'io.github.bugroo.tidydrop.agent.community.v7' ] || {
        printf '%s\n' '[FALLO] El label comunitario actual no coincide con build 7.' >&2
        exit 1
    }
    printf '%s\n' '[OK] Plists válidos'
    printf '%s\n' '[OK] Versión e identidad comunitaria coherentes'
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
unexpected_unlinks=$(
    /usr/bin/grep -RInE '(^|[^[:alnum:]_])unlink[[:space:]]*\(' "$PROJECT_ROOT/Sources" 2>/dev/null \
        | /usr/bin/grep -v '/FileSystem.swift:' \
        || true
)
if [ -n "$unexpected_unlinks" ] \
   || ! /usr/bin/grep -q 'APP_OWNED_TRANSIENT_SIGNAL' "$PROJECT_ROOT/Sources/TidyDropCore/FileSystem.swift" \
   || ! /usr/bin/grep -q 'lastPathComponent == "agent-run-request.json"' \
        "$PROJECT_ROOT/Sources/TidyDropCore/FileSystem.swift"; then
    printf '%s\n' '[FALLO] La señal transitoria no está eliminada por una primitiva exacta y acotada.' >&2
    [ -z "$unexpected_unlinks" ] || printf '%s\n' "$unexpected_unlinks" >&2
    exit 1
fi
if /usr/bin/grep -n 'removeItem' "$PROJECT_ROOT/Sources/TidyDropCore/StewardEngine.swift" >/dev/null 2>&1; then
    printf '%s\n' '[FALLO] El motor de organización no debe borrar archivos.' >&2
    exit 1
fi
printf '%s\n' '[OK] Sin borrado en la carpeta activa; solo retención propia y señal interna exacta'

if ! /usr/bin/grep -q 'renameatx_np' "$PROJECT_ROOT/Sources/TidyDropCore/FileSystem.swift" \
   || ! /usr/bin/grep -q 'RENAME_EXCL' "$PROJECT_ROOT/Sources/TidyDropCore/FileSystem.swift"; then
    printf '%s\n' '[FALLO] Falta el rename exclusivo de macOS.' >&2
    exit 1
fi
if /usr/bin/grep -n 'moveItem' "$PROJECT_ROOT/Sources/TidyDropCore/StewardEngine.swift" >/dev/null 2>&1; then
    printf '%s\n' '[FALLO] El motor no debe depender de moveItem para apply/undo.' >&2
    exit 1
fi
if ! /usr/bin/grep -q 'O_NOFOLLOW' "$PROJECT_ROOT/Sources/TidyDropCore/FileSystem.swift"; then
    printf '%s\n' '[FALLO] Faltan aperturas POSIX sin seguimiento de symlinks.' >&2
    exit 1
fi
printf '%s\n' '[OK] Apply/undo con rename exclusivo y archivos propios abiertos con O_NOFOLLOW'

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

if ! /usr/bin/grep -q '\.linkedLibrary("sqlite3")' "$PROJECT_ROOT/Package.swift" \
   || ! /usr/bin/grep -q 'SQLITE_OPEN_NOFOLLOW' \
        "$PROJECT_ROOT/Sources/TidyDropCore/AgentActivityDatabase.swift" \
   || ! /usr/bin/grep -q 'SQLITE_OPEN_READONLY' \
        "$PROJECT_ROOT/Sources/TidyDropCore/AgentActivityDatabase.swift" \
   || ! /usr/bin/grep -q 'PRAGMA trusted_schema=OFF' \
        "$PROJECT_ROOT/Sources/TidyDropCore/AgentActivityDatabase.swift" \
   || ! /usr/bin/grep -q 'APP_OWNED_SQLITE_RETENTION' \
        "$PROJECT_ROOT/Sources/TidyDropCore/AgentActivityDatabase.swift"; then
    printf '%s\n' '[FALLO] El índice SQLite perdió un control obligatorio.' >&2
    exit 1
fi
unexpected_activity_writers=$(
    /usr/bin/grep -RIn 'AgentActivityDatabase.record' "$PROJECT_ROOT/Sources" 2>/dev/null \
        | /usr/bin/grep -v '/ScheduledExecution.swift:' \
        || true
)
if [ -n "$unexpected_activity_writers" ]; then
    printf '%s\n' '[FALLO] Solo la ejecución programada puede escribir el índice SQLite.' >&2
    printf '%s\n' "$unexpected_activity_writers" >&2
    exit 1
fi
printf '%s\n' '[OK] Índice SQLite derivado con escritor único, reader read-only y controles de symlink'

if /usr/bin/grep -RInE '(^|[[:space:]])import[[:space:]]+XCTest|\.testTarget[[:space:]]*\(' \
    "$PROJECT_ROOT/Package.swift" "$PROJECT_ROOT/Sources" "$PROJECT_ROOT/SelfTests" >/dev/null 2>&1; then
    printf '%s\n' '[FALLO] Se detectó una dependencia de XCTest.' >&2
    exit 1
fi
printf '%s\n' '[OK] Self-tests ejecutables sin XCTest ni Xcode completo'

if /usr/bin/grep -RInE 'StandardOutPath|StandardErrorPath' \
    "$PROJECT_ROOT/launchd" "$PROJECT_ROOT/app/io.github.bugroo.tidydrop.agent.plist" \
    "$PROJECT_ROOT/app/io.github.bugroo.tidydrop.agent.community.v5.plist" \
    "$PROJECT_ROOT/app/io.github.bugroo.tidydrop.agent.community.v6.plist" \
    "$PROJECT_ROOT/app/io.github.bugroo.tidydrop.agent.community.v7.plist" \
    "$PROJECT_ROOT/scripts/render-launchagent.sh" >/dev/null 2>&1; then
    printf '%s\n' '[FALLO] El LaunchAgent no debe crear stdout/stderr ilimitados.' >&2
    exit 1
fi
printf '%s\n' '[OK] LaunchAgent sin logs stdout/stderr ilimitados'

if /usr/bin/grep -q -- '--entitlements' "$PROJECT_ROOT/scripts/sign-app.sh"; then
    printf '%s\n' '[FALLO] Sandbox no puede entrar en releases antes del gate integrado.' >&2
    exit 1
fi
if /usr/bin/grep -E 'com.apple.security.network|com.apple.security.temporary-exception' \
    "$PROJECT_ROOT/app/TidyDrop.entitlements" \
    "$PROJECT_ROOT/app/TidyDropAgent.entitlements" >/dev/null 2>&1; then
    printf '%s\n' '[FALLO] Los prototipos Sandbox contienen entitlements excesivos.' >&2
    exit 1
fi
printf '%s\n' '[OK] Prototipos Sandbox mínimos y bloqueados fuera de releases'

if ! /usr/bin/grep -q 'notarytool submit' "$PROJECT_ROOT/scripts/notarize-app.sh" \
   || ! /usr/bin/grep -q -- '--wait' "$PROJECT_ROOT/scripts/notarize-app.sh" \
   || /usr/bin/grep -q -- '--force' "$PROJECT_ROOT/scripts/notarize-app.sh"; then
    printf '%s\n' '[FALLO] La notarización debe esperar, fallar cerrada y no usar --force.' >&2
    exit 1
fi
if ! /usr/bin/grep -q 'notarytool submit' "$PROJECT_ROOT/scripts/notarize-dmg.sh" \
   || ! /usr/bin/grep -q -- '--wait' "$PROJECT_ROOT/scripts/notarize-dmg.sh" \
   || /usr/bin/grep -q -- '--force' "$PROJECT_ROOT/scripts/notarize-dmg.sh"; then
    printf '%s\n' '[FALLO] La notarización del DMG debe esperar, fallar cerrada y no usar --force.' >&2
    exit 1
fi
unexpected_notary=$(
    /usr/bin/grep -RIl \
        --exclude-dir=.git --exclude-dir=.build --exclude='MANIFEST.sha256' \
        'notarytool submit' "$PROJECT_ROOT" 2>/dev/null \
        | /usr/bin/grep -v '/scripts/notarize-app.sh$' \
        | /usr/bin/grep -v '/scripts/notarize-dmg.sh$' \
        | /usr/bin/grep -v '/scripts/audit-project.sh$' \
        | /usr/bin/grep -v '/docs/' \
        || true
)
if [ -n "$unexpected_notary" ]; then
    printf '%s\n' '[FALLO] notarytool submit aparece fuera del script de release controlado.' >&2
    printf '%s\n' "$unexpected_notary" >&2
    exit 1
fi
printf '%s\n' '[OK] Red limitada a notarización Apple durante release; runtime sin red'

invalid_action_refs=$(
    /usr/bin/grep -RhE '^[[:space:]]*uses:[[:space:]]+' "$PROJECT_ROOT/.github/workflows" 2>/dev/null \
        | /usr/bin/awk '
            {
                ref=$0
                sub(/^[[:space:]]*uses:[[:space:]]+/, "", ref)
                sub(/[[:space:]]*#.*/, "", ref)
                if (ref !~ /^actions\/[A-Za-z0-9_.-]+@[0-9a-f]{40}$/) print ref
            }
        ' \
        || true
)
if [ -n "$invalid_action_refs" ]; then
    printf '%s\n' '[FALLO] Toda GitHub Action debe ser oficial actions/* y estar fijada a SHA completo.' >&2
    printf '%s\n' "$invalid_action_refs" >&2
    exit 1
fi
if ! /usr/bin/grep -q 'contents: read' "$PROJECT_ROOT/.github/workflows/release-readiness.yml" \
   || /usr/bin/grep -q 'pull_request_target' "$PROJECT_ROOT/.github/workflows/release-readiness.yml"; then
    printf '%s\n' '[FALLO] El workflow de readiness no conserva privilegios mínimos.' >&2
    exit 1
fi
"$SCRIPT_DIR/test-community-preview-workflow.sh"
printf '%s\n' '[OK] Actions fijadas; PR read-only y publicación comunitaria fail-closed'

if /usr/bin/grep -RIlE \
    --exclude-dir=.git --exclude-dir=.build --exclude-dir=.swiftpm \
    --exclude='*.png' --exclude='*.dmg' --exclude='MANIFEST.sha256' \
    --exclude='audit-project.sh' \
    '/Users/[[:alnum:]_.-]+|Darwin[[:space:]]+[[:alnum:]_.-]+\.local([[:space:]]|$)' \
    "$PROJECT_ROOT" >/dev/null 2>&1; then
    printf '%s\n' '[FALLO] Se detectaron rutas de usuario o hostnames locales en la distribución pública.' >&2
    exit 1
fi
printf '%s\n' '[OK] Evidencia pública sin rutas de usuario ni hostnames locales'

if /usr/bin/grep -RIlE \
    --exclude-dir=.git --exclude-dir=.build --exclude-dir=.swiftpm \
    --exclude='*.png' --exclude='*.dmg' --exclude='MANIFEST.sha256' \
    --exclude='audit-project.sh' \
    'ghp_[[:alnum:]]{20,}|github_pat_[[:alnum:]_]{20,}|AKIA[0-9A-Z]{16}|Bearer[[:space:]]+[[:alnum:]._~+/-]{20,}' \
    "$PROJECT_ROOT" >/dev/null 2>&1; then
    printf '%s\n' '[FALLO] Se detectó un patrón de secreto en la distribución pública.' >&2
    exit 1
fi
printf '%s\n' '[OK] Sin patrones comunes de secretos en la distribución pública'

printf '%s\n' 'Auditoría estática: PASS'
