#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(mktemp -d "/private/tmp/TidyDropIntegration.uninstall.XXXXXX")
trap '/bin/rm -rf "$ROOT"' EXIT HUP INT TERM

TEST_HOME="$ROOT/Home with space"
APP_BUNDLE="$TEST_HOME/Applications/TidyDrop.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/tidydrop"
APP_SUPPORT="$TEST_HOME/Library/Application Support/TidyDrop"
LOG_DIR="$TEST_HOME/Library/Logs/TidyDrop"
LAUNCH_AGENT="$TEST_HOME/Library/LaunchAgents/com.local.tidydrop.plist"
CLI_LINK="$TEST_HOME/.local/bin/tidydrop"
DOWNLOADS="$TEST_HOME/Downloads"

/bin/mkdir -p \
    "$APP_BUNDLE/Contents/MacOS" \
    "$APP_SUPPORT/state/transactions" \
    "$LOG_DIR" \
    "$(dirname -- "$LAUNCH_AGENT")" \
    "$(dirname -- "$CLI_LINK")" \
    "$DOWNLOADS"
: > "$APP_EXECUTABLE"
: > "$APP_SUPPORT/config.json"
: > "$APP_SUPPORT/state/transactions/run.json"
: > "$LOG_DIR/audit.jsonl"
: > "$LAUNCH_AGENT"
: > "$DOWNLOADS/must-survive.txt"
/bin/ln -s "$APP_EXECUTABLE" "$CLI_LINK"

HOME="$TEST_HOME" "$SCRIPT_DIR/uninstall.sh" >/dev/null

[ ! -e "$APP_BUNDLE" ]
[ ! -e "$LAUNCH_AGENT" ]
[ ! -e "$CLI_LINK" ]
[ -f "$APP_SUPPORT/config.json" ]
[ -f "$LOG_DIR/audit.jsonl" ]
[ -f "$DOWNLOADS/must-survive.txt" ]

# A non-symlink command owned by the user must never be removed.
: > "$CLI_LINK"
HOME="$TEST_HOME" "$SCRIPT_DIR/uninstall.sh" --purge >/dev/null

[ ! -e "$APP_SUPPORT" ]
[ ! -e "$LOG_DIR" ]
[ -f "$CLI_LINK" ]
[ -f "$DOWNLOADS/must-survive.txt" ]

if HOME="$TEST_HOME" "$SCRIPT_DIR/uninstall.sh" --unknown >/dev/null 2>&1; then
    printf '%s\n' 'ERROR: una opción de desinstalación desconocida debería fallar.' >&2
    exit 1
fi

printf '%s\n' 'Uninstall safety tests: PASS'
