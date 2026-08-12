#!/bin/sh
set -eu

LABEL='com.local.tidydrop'
APP_BUNDLE="$HOME/Applications/TidyDrop.app"
APP_SUPPORT="$HOME/Library/Application Support/TidyDrop"
LOG_DIR="$HOME/Library/Logs/TidyDrop"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
CLI_LINK="$HOME/.local/bin/tidydrop"
LAUNCHCTL_BIN=${TIDYDROP_LAUNCHCTL_BIN:-/bin/launchctl}
PURGE=0

[ -x "$LAUNCHCTL_BIN" ] || {
    printf 'FALLO: launchctl no es ejecutable: %s\n' "$LAUNCHCTL_BIN" >&2
    exit 1
}

if [ "${1:-}" = '--purge' ]; then
    PURGE=1
elif [ "$#" -gt 0 ]; then
    printf 'Uso: %s [--purge]\n' "$0" >&2
    exit 2
fi

if [ "$(uname -s)" = 'Darwin' ]; then
    UID_VALUE=$(/usr/bin/id -u)
    "$LAUNCHCTL_BIN" bootout "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || true
    "$LAUNCHCTL_BIN" bootout "gui/$UID_VALUE" "$LAUNCH_AGENT" >/dev/null 2>&1 || true
fi

/bin/rm -f "$LAUNCH_AGENT"

if [ -L "$CLI_LINK" ]; then
    target=$(/usr/bin/readlink "$CLI_LINK" || true)
    if [ "$target" = "$APP_BUNDLE/Contents/MacOS/tidydrop" ]; then
        /bin/rm -f "$CLI_LINK"
    fi
fi

/bin/rm -rf "$APP_BUNDLE"

if [ "$PURGE" -eq 1 ]; then
    case "$APP_SUPPORT" in "$HOME/Library/Application Support/TidyDrop") /bin/rm -rf "$APP_SUPPORT" ;; *) exit 1 ;; esac
    case "$LOG_DIR" in "$HOME/Library/Logs/TidyDrop") /bin/rm -rf "$LOG_DIR" ;; *) exit 1 ;; esac
    printf '%s\n' 'Desinstalación completa: agente, aplicación, configuración, estado, transacciones y logs eliminados.'
else
    printf '%s\n' 'Agente y aplicación eliminados. Configuración, transacciones y logs se conservaron.'
    printf 'Para purgar también los datos locales: %s --purge\n' "$0"
fi

printf '%s\n' 'No se han eliminado carpetas ni archivos organizados dentro de la carpeta activa.'
