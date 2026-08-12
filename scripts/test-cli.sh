#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
BINARY=${TIDYDROP_BIN:-"$PROJECT_ROOT/.build/debug/tidydrop"}

if [ ! -x "$BINARY" ]; then
    swift build --package-path "$PROJECT_ROOT"
fi

ROOT=$(mktemp -d "/private/tmp/TidyDropIntegration.cli.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT HUP INT TERM
DOWNLOADS="$ROOT/Downloads"
STATE="$ROOT/state"
LOGS="$ROOT/logs"
CONFIG="$ROOT/config.json"
mkdir -p "$DOWNLOADS"
"$BINARY" print-default-config > "$CONFIG"

if [ "$(uname -s)" = 'Darwin' ] && [ -x /usr/bin/plutil ]; then
    /usr/bin/plutil -replace paths.source_directory -string "$DOWNLOADS" "$CONFIG"
    /usr/bin/plutil -replace paths.destination_root -string "$DOWNLOADS" "$CONFIG"
    /usr/bin/plutil -replace paths.state_directory -string "$STATE" "$CONFIG"
    /usr/bin/plutil -replace paths.log_directory -string "$LOGS" "$CONFIG"
    /usr/bin/plutil -replace stability.minimum_age_seconds -float 0 "$CONFIG"
    /usr/bin/plutil -replace stability.minimum_stable_observations -integer 1 "$CONFIG"
    /usr/bin/plutil -replace stability.probe_delay_milliseconds -integer 0 "$CONFIG"
    /usr/bin/plutil -replace classification.use_mime_fallback -bool false "$CONFIG"
else
    python3 - "$CONFIG" "$DOWNLOADS" "$STATE" "$LOGS" <<'PY'
import json, sys
path, downloads, state, logs = sys.argv[1:]
with open(path, encoding='utf-8') as f:
    cfg = json.load(f)
cfg['paths'].update(
    source_directory=downloads,
    destination_root=downloads,
    state_directory=state,
    log_directory=logs,
)
cfg['stability'].update(
    minimum_age_seconds=0,
    minimum_stable_observations=1,
    probe_delay_milliseconds=0,
)
cfg['classification']['use_mime_fallback'] = False
with open(path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2, sort_keys=True)
    f.write('\n')
PY
fi

printf 'documento\n' > "$DOWNLOADS/CLI prueba.pdf"

if "$BINARY" run --scheduled --dry-run --config "$CONFIG" >/dev/null 2>&1; then
    printf '%s\n' 'ERROR: --scheduled y --dry-run deberían ser incompatibles.' >&2
    exit 1
fi

if "$BINARY" run --apply --config >/dev/null 2>&1; then
    printf '%s\n' 'ERROR: --config sin valor debería fallar cerrado.' >&2
    exit 1
fi

if "$BINARY" run --aply --config "$CONFIG" >/dev/null 2>&1; then
    printf '%s\n' 'ERROR: una opción desconocida debería rechazarse.' >&2
    exit 1
fi

if "$BINARY" undo --apply --dry-run --config "$CONFIG" >/dev/null 2>&1; then
    printf '%s\n' 'ERROR: undo no debería ignorar opciones desconocidas.' >&2
    exit 1
fi

SCHEDULED_STDOUT="$ROOT/scheduled.stdout"
SCHEDULED_STDERR="$ROOT/scheduled.stderr"
"$BINARY" run --scheduled --config "$CONFIG" >"$SCHEDULED_STDOUT" 2>"$SCHEDULED_STDERR"
[ ! -s "$SCHEDULED_STDOUT" ]
[ ! -s "$SCHEDULED_STDERR" ]
[ -f "$STATE/last-scheduled-run.json" ]
grep -q '"outcome"[[:space:]]*:[[:space:]]*"success"' "$STATE/last-scheduled-run.json"
grep -q '"mode"[[:space:]]*:[[:space:]]*"dry-run"' "$STATE/last-scheduled-run.json"
[ -f "$STATE/scheduled-dry-run-cache.json" ]
human_before=$(/usr/bin/wc -c < "$LOGS/steward.log" | /usr/bin/tr -d ' ')
audit_before=$(/usr/bin/wc -c < "$LOGS/audit.jsonl" | /usr/bin/tr -d ' ')
"$BINARY" run --scheduled --config "$CONFIG" >"$SCHEDULED_STDOUT" 2>"$SCHEDULED_STDERR"
[ ! -s "$SCHEDULED_STDOUT" ]
[ ! -s "$SCHEDULED_STDERR" ]
[ "$(/usr/bin/wc -c < "$LOGS/steward.log" | /usr/bin/tr -d ' ')" = "$human_before" ]
[ "$(/usr/bin/wc -c < "$LOGS/audit.jsonl" | /usr/bin/tr -d ' ')" = "$audit_before" ]
grep -q '"planned"[[:space:]]*:[[:space:]]*1' "$STATE/last-scheduled-run.json"

"$BINARY" run --dry-run --config "$CONFIG" >/dev/null
[ -f "$DOWNLOADS/CLI prueba.pdf" ]
[ ! -e "$DOWNLOADS/Documentos/CLI prueba.pdf" ]

"$BINARY" run --apply --config "$CONFIG" >/dev/null
[ ! -e "$DOWNLOADS/CLI prueba.pdf" ]
[ -f "$DOWNLOADS/Documentos/CLI prueba.pdf" ]

"$BINARY" undo --config "$CONFIG" >/dev/null
[ ! -e "$DOWNLOADS/CLI prueba.pdf" ]
[ -f "$DOWNLOADS/Documentos/CLI prueba.pdf" ]

"$BINARY" undo --apply --config "$CONFIG" >/dev/null
[ -f "$DOWNLOADS/CLI prueba.pdf" ]
[ ! -e "$DOWNLOADS/Documentos/CLI prueba.pdf" ]

"$BINARY" activate --config "$CONFIG" >/dev/null
"$BINARY" status --config "$CONFIG" | grep -q 'modo programado: apply'
OTHER_FOLDER="$ROOT/Carpeta ü con espacios"
mkdir -p "$OTHER_FOLDER"
OTHER_FOLDER=$(CDPATH= cd -- "$OTHER_FOLDER" && pwd -P)
mkdir -p "$STATE/transactions"
printf '%s\n' 'preserve' >"$STATE/transactions/preserve.marker"
"$BINARY" folder set "$OTHER_FOLDER" --config "$CONFIG" >"$ROOT/folder-set.txt"
grep -q 'apply_enabled=false' "$ROOT/folder-set.txt"
"$BINARY" folder show --config "$CONFIG" >"$ROOT/folder-show.txt"
CONFIGURED_FOLDER=$(/usr/bin/plutil -extract paths.source_directory raw -o - "$CONFIG")
[ -d "$CONFIGURED_FOLDER" ]
[ "$(/usr/bin/plutil -extract paths.destination_root raw -o - "$CONFIG")" = "$CONFIGURED_FOLDER" ]
grep -q '^ruta canónica: ' "$ROOT/folder-show.txt"
grep -q 'modo: dry-run' "$ROOT/folder-show.txt"
[ -f "$STATE/transactions/preserve.marker" ]
if "$BINARY" folder set / --config "$CONFIG" >/dev/null 2>&1; then
    printf '%s\n' 'ERROR: folder set debe rechazar /.' >&2
    exit 1
fi
"$BINARY" folder validate --config "$CONFIG" | grep -q 'validación: OK'
"$BINARY" deactivate --config "$CONFIG" >/dev/null
"$BINARY" status --config "$CONFIG" | grep -q 'modo programado: dry-run'

MISSING_SOURCE="$ROOT/unmounted-source"
/usr/bin/plutil -replace paths.source_directory -string "$MISSING_SOURCE" "$CONFIG"
/usr/bin/plutil -replace paths.destination_root -string "$MISSING_SOURCE" "$CONFIG"
"$BINARY" run --scheduled --config "$CONFIG" >"$ROOT/unavailable.stdout" 2>"$ROOT/unavailable.stderr"
[ ! -s "$ROOT/unavailable.stdout" ]
[ ! -s "$ROOT/unavailable.stderr" ]
[ ! -e "$MISSING_SOURCE" ]
grep -q '"outcome"[[:space:]]*:[[:space:]]*"source_unavailable"' "$STATE/last-scheduled-run.json"
grep -q '"moved"[[:space:]]*:[[:space:]]*0' "$STATE/last-scheduled-run.json"

printf '%s\n' 'CLI integration tests: PASS'
