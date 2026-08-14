#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
AGENT_BINARY=${TIDYDROP_AGENT_BIN:-"$PROJECT_ROOT/.build/debug/tidydrop-agent"}
CLI_BINARY=${TIDYDROP_BIN:-"$PROJECT_ROOT/.build/debug/tidydrop"}

if [ ! -x "$AGENT_BINARY" ] || [ ! -x "$CLI_BINARY" ]; then
    swift build --package-path "$PROJECT_ROOT" -Xswiftc -warnings-as-errors
fi

TEST_ROOT=$(mktemp -d "/private/tmp/TidyDropIntegration.event-agent.XXXXXX")
case "$TEST_ROOT" in
    /private/tmp/TidyDropIntegration.event-agent.*) ;;
    *) printf '%s\n' 'ERROR: unsafe event-agent test root' >&2; exit 1 ;;
esac

AGENT_PID=''
cleanup() {
    if [ -n "$AGENT_PID" ] && /bin/kill -0 "$AGENT_PID" 2>/dev/null; then
        /bin/kill -TERM "$AGENT_PID" 2>/dev/null || true
        wait "$AGENT_PID" 2>/dev/null || true
    fi
    /bin/rm -rf "$TEST_ROOT"
}
trap cleanup EXIT HUP INT TERM

SOURCE="$TEST_ROOT/Watched Folder"
STATE="$TEST_ROOT/state"
LOGS="$TEST_ROOT/logs"
CONFIG="$TEST_ROOT/config.json"
RUN_STATE="$STATE/last-scheduled-run.json"
/bin/mkdir -p "$SOURCE"
"$CLI_BINARY" print-default-config >"$CONFIG"
/usr/bin/plutil -replace paths.source_directory -string "$SOURCE" "$CONFIG"
/usr/bin/plutil -replace paths.destination_root -string "$SOURCE" "$CONFIG"
/usr/bin/plutil -replace paths.state_directory -string "$STATE" "$CONFIG"
/usr/bin/plutil -replace paths.log_directory -string "$LOGS" "$CONFIG"
/usr/bin/plutil -replace stability.minimum_age_seconds -float 0 "$CONFIG"
/usr/bin/plutil -replace stability.minimum_stable_observations -integer 1 "$CONFIG"
/usr/bin/plutil -replace stability.probe_delay_milliseconds -integer 0 "$CONFIG"
/usr/bin/plutil -replace classification.use_mime_fallback -bool false "$CONFIG"
/usr/bin/plutil -replace automation.apply_enabled -bool false "$CONFIG"

run_id() {
    [ -f "$RUN_STATE" ] || return 0
    /usr/bin/plutil -extract run_id raw -o - "$RUN_STATE" 2>/dev/null || true
}

wait_for_new_run() {
    previous_run=$1
    wait_label=$2
    attempts=0
    while [ "$attempts" -lt 25 ]; do
        current_run=$(run_id)
        if [ -n "$current_run" ] && [ "$current_run" != "$previous_run" ]; then
            printf '%s\n' "$current_run"
            return 0
        fi
        attempts=$((attempts + 1))
        /bin/sleep 1
    done
    printf 'ERROR: agent did not produce a new %s run after %s attempts\n' \
        "$wait_label" "$attempts" >&2
    if [ -s "$TEST_ROOT/agent.stderr" ]; then
        /usr/bin/sed -n '1,20p' "$TEST_ROOT/agent.stderr" >&2
    fi
    return 1
}

assert_safe_state() {
    /usr/bin/plutil -extract outcome raw -o - "$RUN_STATE" | /usr/bin/grep -qx 'success'
    /usr/bin/plutil -extract mode raw -o - "$RUN_STATE" | /usr/bin/grep -qx 'dry-run'
    /usr/bin/plutil -extract moved raw -o - "$RUN_STATE" | /usr/bin/grep -qx '0'
    /usr/bin/plutil -extract errors raw -o - "$RUN_STATE" | /usr/bin/grep -qx '0'
    /usr/bin/plutil -extract automation.apply_enabled raw -o - "$CONFIG" | /usr/bin/grep -qx 'false'
}

"$AGENT_BINARY" --config "$CONFIG" >"$TEST_ROOT/agent.stdout" 2>"$TEST_ROOT/agent.stderr" &
AGENT_PID=$!
INITIAL_RUN=$(wait_for_new_run '' 'startup')
assert_safe_state

/usr/bin/printf '%s\n' 'event-driven' >"$SOURCE/event file.pdf"
FILE_EVENT_RUN=$(wait_for_new_run "$INITIAL_RUN" 'source-event')
assert_safe_state
/usr/bin/plutil -extract planned raw -o - "$RUN_STATE" | /usr/bin/grep -qx '1'
[ -f "$SOURCE/event file.pdf" ]
[ ! -e "$SOURCE/Documentos/event file.pdf" ]

burst_index=0
while [ "$burst_index" -lt 8 ]; do
    /usr/bin/printf '%s\n' "$burst_index" >>"$SOURCE/burst.txt"
    burst_index=$((burst_index + 1))
done
BURST_RUN=$(wait_for_new_run "$FILE_EVENT_RUN" 'burst-event')
assert_safe_state
/bin/sleep 5
[ "$(run_id)" = "$BURST_RUN" ]
[ -f "$SOURCE/burst.txt" ]
[ ! -e "$SOURCE/Datos/burst.txt" ]

REQUEST_ID=$(/usr/bin/uuidgen)
REQUEST_TIME=$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')
"$CLI_BINARY" status --json --config "$CONFIG" >"$TEST_ROOT/status.json"
REQUEST_SOURCE=$(/usr/bin/plutil -extract source_directory raw -o - "$TEST_ROOT/status.json")
/usr/bin/printf '{\n  "request_id": "%s",\n  "source_directory": "%s",\n  "timestamp": "%s",\n  "version": 1\n}\n' \
    "$REQUEST_ID" "$REQUEST_SOURCE" "$REQUEST_TIME" >"$STATE/agent-run-request.json"
/bin/chmod 600 "$STATE/agent-run-request.json"
REQUEST_RUN=$(wait_for_new_run "$BURST_RUN" 'app-request')
assert_safe_state

INVALID_REQUEST_ID=$(/usr/bin/uuidgen)
INVALID_REQUEST_TIME=$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')
/usr/bin/printf '{\n  "request_id": "%s",\n  "source_directory": "%s",\n  "timestamp": "%s",\n  "version": 1\n}\n' \
    "$INVALID_REQUEST_ID" "$TEST_ROOT" "$INVALID_REQUEST_TIME" >"$STATE/agent-run-request.json"
/bin/chmod 600 "$STATE/agent-run-request.json"
/bin/sleep 4
[ "$(run_id)" = "$REQUEST_RUN" ]

/bin/sleep 2
CPU_TIME_BEFORE=$(/bin/ps -p "$AGENT_PID" -o time= | /usr/bin/tr -d ' ')
/bin/sleep 4
CPU_TIME_AFTER=$(/bin/ps -p "$AGENT_PID" -o time= | /usr/bin/tr -d ' ')
CPU_PERCENT=$(/bin/ps -p "$AGENT_PID" -o %cpu= | /usr/bin/tr -d ' ')
RSS_KIB=$(/bin/ps -p "$AGENT_PID" -o rss= | /usr/bin/tr -d ' ')
[ "$(run_id)" = "$REQUEST_RUN" ]
[ -z "$(/usr/bin/find "$SOURCE" -mindepth 1 -maxdepth 1 -type d -print -quit)" ]
[ ! -s "$TEST_ROOT/agent.stdout" ]
[ ! -s "$TEST_ROOT/agent.stderr" ]

printf 'Event-driven agent integration: PASS\n'
printf 'Idle sample: cpu_before=%s cpu_after=%s cpu_percent=%s rss_kib=%s\n' \
    "$CPU_TIME_BEFORE" "$CPU_TIME_AFTER" "$CPU_PERCENT" "$RSS_KIB"
printf 'Personal files moved: 0\n'
