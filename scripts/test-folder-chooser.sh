#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
BINARY=${TIDYDROP_BIN:-"$PROJECT_ROOT/.build/debug/tidydrop"}

if [ "$(uname -s)" != 'Darwin' ]; then
    printf '%s\n' 'Folder chooser test: SKIP (requiere macOS)'
    exit 0
fi
[ -x "$BINARY" ] || { printf 'FALLO: falta %s\n' "$BINARY" >&2; exit 1; }

ROOT=$(mktemp -d "/private/tmp/TidyDropIntegration.folder-chooser.XXXXXX")
trap '/bin/rm -rf "$ROOT"' EXIT HUP INT TERM
CONFIG="$ROOT/config.json"
/bin/cp "$PROJECT_ROOT/config/config.example.json" "$CONFIG"
before=$(/usr/bin/shasum -a 256 "$CONFIG" | /usr/bin/awk '{print $1}')

output=$(TIDYDROP_TEST_CHOOSER_CANCEL_AFTER_MS=150 \
    "$BINARY" folder choose --config "$CONFIG")
printf '%s\n' "$output" | /usr/bin/grep -q 'Selección cancelada; la configuración no cambió.'
after=$(/usr/bin/shasum -a 256 "$CONFIG" | /usr/bin/awk '{print $1}')
[ "$before" = "$after" ]

printf '%s\n' 'Native folder chooser open/cancel test: PASS'
