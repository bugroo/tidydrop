#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(mktemp -d "/private/tmp/TidyDropIntegration.launchagent.XXXXXX")
trap '/bin/rm -rf "$ROOT"' EXIT HUP INT TERM

PLUTIL_BIN=$(command -v plutil 2>/dev/null || true)
[ -n "$PLUTIL_BIN" ] || { printf '%s\n' 'ERROR: plutil no está disponible.' >&2; exit 1; }

HOME_VALUE="$ROOT/Home with space"
EXECUTABLE="$HOME_VALUE/Applications/TidyDrop.app/Contents/MacOS/tidydrop"
CONFIG="$HOME_VALUE/Library/Application Support/TidyDrop/config.json"
OUTPUT="$ROOT/com.local.tidydrop.plist"

PLUTIL="$PLUTIL_BIN" "$SCRIPT_DIR/render-launchagent.sh" \
    "$OUTPUT" "$EXECUTABLE" "$CONFIG" 300 "$HOME_VALUE" >/dev/null

[ "$("$PLUTIL_BIN" -extract Label raw -o - "$OUTPUT")" = 'com.local.tidydrop' ]
[ "$("$PLUTIL_BIN" -extract ProgramArguments.0 raw -o - "$OUTPUT")" = "$EXECUTABLE" ]
[ "$("$PLUTIL_BIN" -extract ProgramArguments.1 raw -o - "$OUTPUT")" = 'run' ]
[ "$("$PLUTIL_BIN" -extract ProgramArguments.2 raw -o - "$OUTPUT")" = '--scheduled' ]
[ "$("$PLUTIL_BIN" -extract ProgramArguments.4 raw -o - "$OUTPUT")" = "$CONFIG" ]
[ "$("$PLUTIL_BIN" -extract StartInterval raw -o - "$OUTPUT")" = '300' ]
[ "$("$PLUTIL_BIN" -extract RunAtLoad raw -o - "$OUTPUT")" = 'true' ]
[ "$("$PLUTIL_BIN" -extract Umask raw -o - "$OUTPUT")" = '63' ]
[ "$("$PLUTIL_BIN" -extract EnvironmentVariables.HOME raw -o - "$OUTPUT")" = "$HOME_VALUE" ]
[ "$("$PLUTIL_BIN" -extract AssociatedBundleIdentifiers.0 raw -o - "$OUTPUT")" = 'com.local.tidydrop' ]

if "$PLUTIL_BIN" -extract StandardOutPath raw -o - "$OUTPUT" >/dev/null 2>&1; then
    printf '%s\n' 'ERROR: StandardOutPath no debe generar un log ilimitado.' >&2
    exit 1
fi
if "$PLUTIL_BIN" -extract StandardErrorPath raw -o - "$OUTPUT" >/dev/null 2>&1; then
    printf '%s\n' 'ERROR: StandardErrorPath no debe generar un log ilimitado.' >&2
    exit 1
fi

mode=$(stat -c '%a' "$OUTPUT" 2>/dev/null || stat -f '%Lp' "$OUTPUT")
[ "$mode" = '600' ]

if PLUTIL="$PLUTIL_BIN" "$SCRIPT_DIR/render-launchagent.sh" \
    "$ROOT/invalid.plist" "$EXECUTABLE" "$CONFIG" 5 "$HOME_VALUE" >/dev/null 2>&1; then
    printf '%s\n' 'ERROR: un intervalo menor de 15 debería rechazarse.' >&2
    exit 1
fi

if /usr/bin/grep -q 'run --dry-run' "$SCRIPT_DIR/verify-install.sh"; then
    printf '%s\n' 'ERROR: verify-install no debe competir con RunAtLoad mediante un dry-run manual.' >&2
    exit 1
fi
/usr/bin/grep -q '"$APP_EXECUTABLE" run --dry-run --config "$CONFIG_FILE"' \
    "$SCRIPT_DIR/install.sh"
if /usr/bin/grep -q 'plutil -lint "\$STATUS_FILE"' "$SCRIPT_DIR/verify-install.sh"; then
    printf '%s\n' 'ERROR: el estado JSON no debe validarse como plist mediante plutil -lint.' >&2
    exit 1
fi
/usr/bin/grep -q 'plutil -extract run_id raw' "$SCRIPT_DIR/verify-install.sh"
/usr/bin/grep -q 'plutil -extract moved raw' "$SCRIPT_DIR/verify-install.sh"
if /usr/bin/grep -q 'kickstart -k' "$SCRIPT_DIR/verify-install.sh"; then
    printf '%s\n' 'ERROR: verify-install no debe matar la pasada RunAtLoad en curso.' >&2
    exit 1
fi
/usr/bin/grep -q 'TIDYDROP_PRE_BOOTSTRAP_RUN_ID' "$SCRIPT_DIR/install.sh"
/usr/bin/grep -q 'while \[ "$attempt" -lt 180 \]' "$SCRIPT_DIR/verify-install.sh"

printf '%s\n' 'LaunchAgent rendering and verification sequencing tests: PASS'
