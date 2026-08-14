#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
BINARY=${TIDYDROP_BIN:-"$PROJECT_ROOT/.build/debug/tidydrop"}
SOURCE="$PROJECT_ROOT/Sources/TidyDrop/main.swift"
SELF_TESTS="$PROJECT_ROOT/SelfTests/TidyDropSelfTests/main.swift"
INTERACTIVE=${TIDYDROP_RUN_INTERACTIVE_FOLDER_CHOOSER_TEST:-0}

if [ "$(uname -s)" != 'Darwin' ]; then
    printf '%s\n' 'Folder chooser test: SKIP (requiere macOS)'
    exit 0
fi
[ -x "$BINARY" ] || { printf 'FALLO: falta %s\n' "$BINARY" >&2; exit 1; }
[ -f "$SOURCE" ] || { printf 'FALLO: falta %s\n' "$SOURCE" >&2; exit 1; }
[ -f "$SELF_TESTS" ] || { printf 'FALLO: falta %s\n' "$SELF_TESTS" >&2; exit 1; }

case "$INTERACTIVE" in
    0|1) ;;
    *)
        printf '%s\n' 'FALLO: TIDYDROP_RUN_INTERACTIVE_FOLDER_CHOOSER_TEST debe ser 0 o 1.' >&2
        exit 1
        ;;
esac

for required in \
    'let panel = NSOpenPanel()' \
    'panel.canChooseDirectories = true' \
    'panel.canChooseFiles = false' \
    'panel.allowsMultipleSelection = false' \
    'panel.canCreateDirectories = true' \
    'ActiveFolderManager.applySelection' \
    'testCancelledFolderSelectionDoesNotChangeConfiguration'; do
    /usr/bin/grep -F -q -- "$required" "$SOURCE" "$SELF_TESTS" || {
        printf 'FALLO: contrato del selector ausente: %s\n' "$required" >&2
        exit 1
    }
done

"$BINARY" help | /usr/bin/grep -F -q 'tidydrop folder choose'

if [ "$INTERACTIVE" -ne 1 ]; then
    printf '%s\n' 'Native folder chooser nonvisual contract: PASS (interactive panel not opened)'
    exit 0
fi

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

printf '%s\n' 'Native folder chooser explicit open/cancel test: PASS'
