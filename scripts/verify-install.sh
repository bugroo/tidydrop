#!/bin/sh
set -eu

LABEL='com.local.tidydrop'
APP_BUNDLE="$HOME/Applications/TidyDrop.app"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/tidydrop"
CONFIG_FILE="$HOME/Library/Application Support/TidyDrop/config.json"
STATE_DIR="$HOME/Library/Application Support/TidyDrop/state"
STATUS_FILE="$STATE_DIR/last-scheduled-run.json"
LOG_DIR="$HOME/Library/Logs/TidyDrop"
AGENT_ERROR_LOG="$LOG_DIR/agent-errors.log"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ "$(uname -s)" != 'Darwin' ]; then
    printf '%s\n' 'ERROR: verify-install.sh debe ejecutarse en macOS.' >&2
    exit 1
fi

[ -x "$EXECUTABLE" ] || { printf 'FALLO: falta %s\n' "$EXECUTABLE" >&2; exit 1; }
[ -f "$CONFIG_FILE" ] || { printf 'FALLO: falta %s\n' "$CONFIG_FILE" >&2; exit 1; }
[ -f "$LAUNCH_AGENT" ] || { printf 'FALLO: falta %s\n' "$LAUNCH_AGENT" >&2; exit 1; }

/usr/bin/codesign --verify --strict "$APP_BUNDLE"
/usr/bin/plutil -lint "$APP_BUNDLE/Contents/Info.plist"
/usr/bin/plutil -extract NSDownloadsFolderUsageDescription raw -o - "$APP_BUNDLE/Contents/Info.plist" >/dev/null
/usr/bin/plutil -extract NSDocumentsFolderUsageDescription raw -o - "$APP_BUNDLE/Contents/Info.plist" >/dev/null
/usr/bin/plutil -extract NSDesktopFolderUsageDescription raw -o - "$APP_BUNDLE/Contents/Info.plist" >/dev/null
/usr/bin/plutil -extract NSRemovableVolumesUsageDescription raw -o - "$APP_BUNDLE/Contents/Info.plist" >/dev/null
/usr/bin/plutil -extract NSNetworkVolumesUsageDescription raw -o - "$APP_BUNDLE/Contents/Info.plist" >/dev/null
/usr/bin/plutil -lint "$LAUNCH_AGENT"
if /usr/bin/plutil -extract StandardOutPath raw -o - "$LAUNCH_AGENT" >/dev/null 2>&1; then
    printf '%s\n' 'FALLO: el LaunchAgent contiene StandardOutPath ilimitado.' >&2
    exit 1
fi
if /usr/bin/plutil -extract StandardErrorPath raw -o - "$LAUNCH_AGENT" >/dev/null 2>&1; then
    printf '%s\n' 'FALLO: el LaunchAgent contiene StandardErrorPath ilimitado.' >&2
    exit 1
fi

"$EXECUTABLE" status --config "$CONFIG_FILE" | /usr/bin/grep -q 'modo programado: dry-run'
"$EXECUTABLE" doctor --config "$CONFIG_FILE"

# install.sh ya verificó el dry-run manual antes de bootstrap. RunAtLoad puede
# estar ejecutando la primera pasada aquí; no competir con ella por run.lock.

UID_VALUE=$(/usr/bin/id -u)
/bin/launchctl print "gui/$UID_VALUE/$LABEL" >/dev/null

before=${TIDYDROP_PRE_BOOTSTRAP_RUN_ID:-}
if [ -z "$before" ] && [ -f "$STATUS_FILE" ]; then
    before=$(/usr/bin/plutil -extract run_id raw -o - "$STATUS_FILE" 2>/dev/null || true)
fi
# No matar RunAtLoad: una pasada con muchos candidatos puede seguir activa.
# kickstart sin -k garantiza demanda si todavía no arrancó y es no destructivo si corre.
/bin/launchctl kickstart "gui/$UID_VALUE/$LABEL"

after=$before
attempt=0
while [ "$attempt" -lt 180 ]; do
    /bin/sleep 1
    if [ -f "$STATUS_FILE" ]; then
        after=$(/usr/bin/plutil -extract run_id raw -o - "$STATUS_FILE" 2>/dev/null || true)
    fi
    [ -n "$after" ] && [ "$after" != "$before" ] && break
    attempt=$((attempt + 1))
done

if [ -z "$after" ] || [ "$after" = "$before" ]; then
    printf '%s\n' 'FALLO: el LaunchAgent no actualizó last-scheduled-run.json en 180 segundos.' >&2
    if [ -f "$AGENT_ERROR_LOG" ]; then
        printf '%s\n' 'Últimas líneas del log acotado agent-errors.log:' >&2
        /usr/bin/tail -n 30 "$AGENT_ERROR_LOG" >&2 || true
    fi
    printf '%s\n' 'Revisa únicamente TidyDrop en Privacidad y seguridad → Archivos y carpetas.' >&2
    printf '%s\n' 'No concedas Acceso total al disco.' >&2
    exit 1
fi

# `plutil -lint` solo valida plists en esta versión de macOS y rechaza JSON.
# Las extracciones siguientes parsean y validan estructuralmente el estado JSON.
run_id=$(/usr/bin/plutil -extract run_id raw -o - "$STATUS_FILE")
outcome=$(/usr/bin/plutil -extract outcome raw -o - "$STATUS_FILE")
mode=$(/usr/bin/plutil -extract mode raw -o - "$STATUS_FILE" 2>/dev/null || true)
scanned=$(/usr/bin/plutil -extract scanned raw -o - "$STATUS_FILE")
moved=$(/usr/bin/plutil -extract moved raw -o - "$STATUS_FILE")
errors=$(/usr/bin/plutil -extract errors raw -o - "$STATUS_FILE" 2>/dev/null || printf '0')
if [ -z "$run_id" ] || [ "$outcome" != 'success' ] || [ "$mode" != 'dry-run' ] \
   || [ "$moved" != '0' ] || [ "$errors" != '0' ]; then
    printf 'FALLO: pasada programada run_id=%s outcome=%s mode=%s scanned=%s moved=%s errors=%s.\n' \
        "$run_id" "$outcome" "$mode" "$scanned" "$moved" "$errors" >&2
    if [ -f "$AGENT_ERROR_LOG" ]; then
        /usr/bin/tail -n 30 "$AGENT_ERROR_LOG" >&2 || true
    fi
    printf '%s\n' 'No concedas Acceso total al disco; revisa solo Files & Folders para TidyDrop.' >&2
    exit 1
fi

/bin/launchctl print "gui/$UID_VALUE/$LABEL" >/dev/null
printf '%s\n' 'Verificación completada: bundle, firma local, configuración y pasada del LaunchAgent.'
printf '%s\n' 'TCC comprobado mediante lectura real de la carpeta activa desde el agente; estado confirmado en dry-run.'
