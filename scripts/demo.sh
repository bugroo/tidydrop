#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
BINARY=${TIDYDROP_BIN:-"$PROJECT_ROOT/.build/debug/tidydrop"}
KEEP=0
[ "${1:-}" = '--keep' ] && KEEP=1

if [ ! -x "$BINARY" ]; then
    swift build --package-path "$PROJECT_ROOT"
fi

ROOT=$(mktemp -d "/private/tmp/TidyDropIntegration.demo.XXXXXX")
DOWNLOADS="$ROOT/Downloads"
STATE="$ROOT/state"
LOGS="$ROOT/logs"
CONFIG="$ROOT/config.json"
mkdir -p "$DOWNLOADS/Example.app"

printf 'PDF de ejemplo\n' > "$DOWNLOADS/Informe final 2026.pdf"
printf 'PNG de ejemplo\n' > "$DOWNLOADS/Foto vacaciones ü.png"
printf 'archivo\n' > "$DOWNLOADS/copia.tar.gz"
printf 'a,b,c\n1,2,3\n' > "$DOWNLOADS/datos.csv"
printf 'FROM scratch\n' > "$DOWNLOADS/Dockerfile"
printf 'incompleto\n' > "$DOWNLOADS/video.mp4.crdownload"
printf 'oculto\n' > "$DOWNLOADS/.oculto.txt"
ln -s "Informe final 2026.pdf" "$DOWNLOADS/alias.pdf"

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
    /usr/bin/plutil -replace logging.log_skipped_files -bool true "$CONFIG"
elif command -v python3 >/dev/null 2>&1; then
    # Fallback exclusivo para CI/desarrollo fuera de macOS.
    python3 - "$CONFIG" "$DOWNLOADS" "$STATE" "$LOGS" <<'PY'
import json, sys
path, downloads, state, logs = sys.argv[1:]
with open(path, encoding='utf-8') as f:
    cfg = json.load(f)
cfg['paths']['source_directory'] = downloads
cfg['paths']['destination_root'] = downloads
cfg['paths']['state_directory'] = state
cfg['paths']['log_directory'] = logs
cfg['stability']['minimum_age_seconds'] = 0
cfg['stability']['minimum_stable_observations'] = 1
cfg['stability']['probe_delay_milliseconds'] = 0
cfg['classification']['use_mime_fallback'] = False
cfg['logging']['log_skipped_files'] = True
with open(path, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2, sort_keys=True)
    f.write('\n')
PY
else
    printf '%s\n' 'ERROR: no se pudo preparar la configuración de demostración.' >&2
    exit 1
fi

printf '%s\n' '=== Dry-run de demostración ==='
"$BINARY" run --dry-run --config "$CONFIG"
printf '\n%s\n' '=== Contenido de Downloads después del dry-run (sin movimientos) ==='
/usr/bin/find "$DOWNLOADS" -print | /usr/bin/sed '1d' | LC_ALL=C /usr/bin/sort
printf '\nLogs: %s\n' "$LOGS"

if [ "$KEEP" -eq 1 ]; then
    printf 'Directorio conservado: %s\n' "$ROOT"
else
    rm -rf "$ROOT"
fi
