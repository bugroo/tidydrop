#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
BIN_DIR=${TIDYDROP_DEBUG_BIN_DIR:-"$PROJECT_ROOT/.build/debug"}
SELF_TEST_BINARY=${TIDYDROP_SELF_TEST_BIN:-"$BIN_DIR/tidydrop-self-test"}
HELPER_BINARY=${TIDYDROP_RECOVERY_HELPER_BIN:-"$BIN_DIR/tidydrop-recovery-helper"}
REPETITIONS=${TIDYDROP_STATE_RESTORATION_KILL_REPETITIONS:-5}
TEST_NAME=testRecoveryHelperRestoresStateAfterProcessKillAtEveryBoundary

fail() {
    printf '%s\n' "ERROR: $1" >&2
    exit 1
}

test -x "$SELF_TEST_BINARY" || fail "self-test binary missing: $SELF_TEST_BINARY"
test -x "$HELPER_BINARY" || fail "recovery helper missing: $HELPER_BINARY"

case "$REPETITIONS" in
    ''|*[!0-9]*) fail 'repetition count must be an integer from 1 through 20' ;;
esac
[ "$REPETITIONS" -ge 1 ] && [ "$REPETITIONS" -le 20 ] \
    || fail 'repetition count must be an integer from 1 through 20'

iteration=1
while [ "$iteration" -le "$REPETITIONS" ]; do
    printf 'State restoration kill/relaunch iteration %s/%s\n' \
        "$iteration" "$REPETITIONS"
    env \
        TIDYDROP_RECOVERY_HELPER_BIN="$HELPER_BINARY" \
        TIDYDROP_SELF_TEST_FILTER="$TEST_NAME" \
        "$SELF_TEST_BINARY"
    iteration=$((iteration + 1))
done

kill_count=$((REPETITIONS * 5))
printf '%s\n' \
    "State restoration process kill/relaunch: PASS ($kill_count forced kills across 5 durable boundaries)"
