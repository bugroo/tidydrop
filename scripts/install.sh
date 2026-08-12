#!/bin/sh
set -eu

umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
LABEL='com.local.tidydrop'
APP_BUNDLE="$HOME/Applications/TidyDrop.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/tidydrop"
APP_SUPPORT="$HOME/Library/Application Support/TidyDrop"
CONFIG_FILE="$APP_SUPPORT/config.json"
STATE_DIR="$APP_SUPPORT/state"
LOG_DIR="$HOME/Library/Logs/TidyDrop"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
CLI_LINK="$HOME/.local/bin/tidydrop"
INFO_PLIST_SOURCE="$PROJECT_ROOT/app/Info.plist"

if [ "$(uname -s)" != 'Darwin' ]; then
    printf '%s\n' 'ERROR: install.sh debe ejecutarse en macOS.' >&2
    exit 1
fi

printf '\n[1/8] Verificando macOS y Apple Command Line Tools, sin XCTest...\n'
"$SCRIPT_DIR/doctor.sh"

printf '\n[2/8] Compilando binarios release con advertencias tratadas como errores...\n'
/usr/bin/xcrun swift build --package-path "$PROJECT_ROOT" -c release -Xswiftc -warnings-as-errors
BIN_DIR=$(/usr/bin/xcrun swift build --package-path "$PROJECT_ROOT" -c release --show-bin-path)
BUILT_BINARY="$BIN_DIR/tidydrop"
SELF_TEST_BINARY="$BIN_DIR/tidydrop-self-test"
[ -x "$BUILT_BINARY" ] || { printf 'ERROR: binario no encontrado: %s\n' "$BUILT_BINARY" >&2; exit 1; }
[ -x "$SELF_TEST_BINARY" ] || { printf 'ERROR: self-test no encontrado: %s\n' "$SELF_TEST_BINARY" >&2; exit 1; }
/usr/bin/plutil -lint "$INFO_PLIST_SOURCE"

printf '\n[3/8] Ejecutando self-tests, integración CLI y demo aislada...\n'
"$SELF_TEST_BINARY"
"$SCRIPT_DIR/test-doctor.sh"
TIDYDROP_BIN="$BUILT_BINARY" "$SCRIPT_DIR/test-folder-chooser.sh"
TIDYDROP_BIN="$BUILT_BINARY" "$SCRIPT_DIR/test-cli.sh"
"$SCRIPT_DIR/test-launchagent.sh"
"$SCRIPT_DIR/test-uninstall.sh"
TIDYDROP_BIN="$BUILT_BINARY" "$SCRIPT_DIR/demo.sh"

printf '\n[4/8] Deteniendo una instalación anterior antes de reemplazar componentes...\n'
UID_VALUE=$(/usr/bin/id -u)
/bin/launchctl bootout "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || true
/bin/launchctl bootout "gui/$UID_VALUE" "$LAUNCH_AGENT" >/dev/null 2>&1 || true

printf '\n[5/8] Instalando bundle local y configuración...\n'
/bin/mkdir -p "$HOME/Applications" "$APP_SUPPORT" "$STATE_DIR" "$LOG_DIR" "$HOME/Library/LaunchAgents" "$HOME/.local/bin"

REPLACE_APP=1
if [ -x "$APP_EXECUTABLE" ] && [ -f "$APP_BUNDLE/Contents/Info.plist" ]; then
    if /usr/bin/cmp -s "$BUILT_BINARY" "$APP_EXECUTABLE" \
       && /usr/bin/cmp -s "$INFO_PLIST_SOURCE" "$APP_BUNDLE/Contents/Info.plist" \
       && /usr/bin/codesign --verify --strict "$APP_BUNDLE" >/dev/null 2>&1; then
        REPLACE_APP=0
    fi
fi

if [ "$REPLACE_APP" -eq 1 ]; then
    STAGING_APP="$HOME/Applications/.TidyDrop.app.new.$$"
    OLD_APP="$HOME/Applications/.TidyDrop.app.old.$$"
    /bin/rm -rf "$STAGING_APP" "$OLD_APP"
    /bin/mkdir -p "$STAGING_APP/Contents/MacOS"
    /bin/cp "$BUILT_BINARY" "$STAGING_APP/Contents/MacOS/tidydrop"
    /bin/cp "$INFO_PLIST_SOURCE" "$STAGING_APP/Contents/Info.plist"
    /bin/chmod 700 "$STAGING_APP/Contents/MacOS/tidydrop"
    /usr/bin/plutil -lint "$STAGING_APP/Contents/Info.plist"
    /usr/bin/codesign --force --sign - --identifier "$LABEL" "$STAGING_APP" >/dev/null
    /usr/bin/codesign --verify --strict "$STAGING_APP"

    if [ -e "$APP_BUNDLE" ]; then
        /bin/mv "$APP_BUNDLE" "$OLD_APP"
    fi
    if ! /bin/mv "$STAGING_APP" "$APP_BUNDLE"; then
        [ ! -e "$OLD_APP" ] || /bin/mv "$OLD_APP" "$APP_BUNDLE"
        exit 1
    fi
    /bin/rm -rf "$OLD_APP"
    printf 'Bundle instalado: %s\n' "$APP_BUNDLE"
else
    printf 'Bundle idéntico preservado para evitar cambiar innecesariamente su identidad local.\n'
fi

if [ ! -e "$CONFIG_FILE" ]; then
    /bin/cp "$PROJECT_ROOT/config/config.example.json" "$CONFIG_FILE"
    printf 'Configuración inicial creada en %s\n' "$CONFIG_FILE"
else
    printf 'Reglas, rutas e intervalo existentes preservados: %s\n' "$CONFIG_FILE"
fi
/bin/chmod 600 "$CONFIG_FILE"

# Invariante de instalación: cada instalación o actualización vuelve a dry-run.
# Al guardar, una configuración 1.0.0 recibe también los límites seguros nuevos.
"$APP_EXECUTABLE" deactivate --config "$CONFIG_FILE"

if [ -L "$CLI_LINK" ] || [ ! -e "$CLI_LINK" ]; then
    /bin/ln -sfn "$APP_EXECUTABLE" "$CLI_LINK"
else
    printf 'AVISO: no se reemplazó %s porque ya existe y no es un enlace simbólico.\n' "$CLI_LINK" >&2
fi

printf '\n[6/8] Validando configuración y acceso manual en modo seguro...\n'
"$APP_EXECUTABLE" status --config "$CONFIG_FILE"
"$APP_EXECUTABLE" doctor --config "$CONFIG_FILE"
"$APP_EXECUTABLE" run --dry-run --config "$CONFIG_FILE"

INTERVAL=$(/usr/bin/plutil -extract automation.interval_seconds raw -o - "$CONFIG_FILE" 2>/dev/null || printf '300')
case "$INTERVAL" in
    ''|*[!0-9]*) INTERVAL=300 ;;
esac
if [ "$INTERVAL" -lt 15 ]; then INTERVAL=300; fi

printf '\n[7/8] Generando y cargando LaunchAgent de usuario en dry-run...\n'
PRE_BOOTSTRAP_RUN_ID=''
if [ -f "$STATE_DIR/last-scheduled-run.json" ]; then
    PRE_BOOTSTRAP_RUN_ID=$(/usr/bin/plutil -extract run_id raw -o - \
        "$STATE_DIR/last-scheduled-run.json" 2>/dev/null || true)
fi
PLUTIL=/usr/bin/plutil "$SCRIPT_DIR/render-launchagent.sh" \
    "$LAUNCH_AGENT" \
    "$APP_EXECUTABLE" \
    "$CONFIG_FILE" \
    "$INTERVAL" \
    "$HOME"
/bin/launchctl bootstrap "gui/$UID_VALUE" "$LAUNCH_AGENT"
/bin/launchctl enable "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || true
/bin/launchctl print "gui/$UID_VALUE/$LABEL" >/dev/null

printf '\n[8/8] Verificando la pasada del LaunchAgent y el acceso específico a la carpeta activa...\n'
if ! TIDYDROP_PRE_BOOTSTRAP_RUN_ID="$PRE_BOOTSTRAP_RUN_ID" "$SCRIPT_DIR/verify-install.sh"; then
    /bin/launchctl bootout "gui/$UID_VALUE/$LABEL" >/dev/null 2>&1 || true
    /bin/launchctl bootout "gui/$UID_VALUE" "$LAUNCH_AGENT" >/dev/null 2>&1 || true
    printf '%s\n' 'ERROR: la verificación falló; el LaunchAgent se descargó y apply_enabled permanece en false.' >&2
    printf '%s\n' 'No concedas Acceso total al disco. Revisa únicamente TidyDrop en Privacidad y seguridad → Archivos y carpetas.' >&2
    printf '%s\n' 'La aplicación y la configuración quedan instaladas para diagnóstico y una reinstalación idempotente.' >&2
    exit 1
fi

cat <<EOF2

TidyDrop 1.0.2 quedó instalado, verificado y cargado en DRY-RUN.

Activación explícita de movimientos automáticos:
  "$CLI_LINK" activate

Ejecución manual real, sin activar la automatización:
  "$CLI_LINK" run --apply

Desactivar movimientos automáticos futuros:
  "$CLI_LINK" deactivate

No se ha usado sudo, Xcode completo ni XCTest. Las pruebas no tocaron tu Downloads real y la instalación no activó movimientos.
EOF2
