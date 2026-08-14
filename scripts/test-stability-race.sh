#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
BINARY=${TIDYDROP_SELF_TEST_BIN:-"$PROJECT_ROOT/.build/debug/tidydrop-self-test"}
[ -x "$BINARY" ] || { printf 'FALLO: falta %s\n' "$BINARY" >&2; exit 1; }

ROOT=$(mktemp -d "/private/tmp/TidyDropIntegration.race.XXXXXX")
trap '/bin/rm -rf "$ROOT"' EXIT HUP INT TERM
FILTER='testChangeDuringProbeDefersMove,testSameSizeMtimeChangeDuringProbeDefersMove,testChangeImmediatelyBeforeMoveDefersMove'
iteration=1
while [ "$iteration" -le 20 ]; do
    output="$ROOT/iteration-$iteration.txt"
    if ! TIDYDROP_SELF_TEST_FILTER="$FILTER" "$BINARY" >"$output" 2>&1; then
        /bin/cat "$output" >&2
        printf 'Stability repetition failed at iteration %s\n' "$iteration" >&2
        exit 1
    fi
    /usr/bin/grep -q '^PASS  testChangeDuringProbeDefersMove$' "$output"
    /usr/bin/grep -q '^PASS  testSameSizeMtimeChangeDuringProbeDefersMove$' "$output"
    /usr/bin/grep -q '^PASS  testChangeImmediatelyBeforeMoveDefersMove$' "$output"
    /usr/bin/grep -q '^Resultado: 3 PASS, 0 SKIP, 0 FAIL; total=3$' "$output"
    summary=$(/usr/bin/tail -n 1 "$output")
    printf 'iteration=%s %s\n' "$iteration" "$summary"
    iteration=$((iteration + 1))
done
printf '%s\n' 'Stability race repetitions: 20/20 PASS'
