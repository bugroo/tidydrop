#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
EVIDENCE_DIR=${1:-"$PROJECT_ROOT/docs/evidence"}
/bin/mkdir -p "$EVIDENCE_DIR"
# Remove the obsolete XCTest-era evidence name when validating an updated tree.
/bin/rm -f "$EVIDENCE_DIR/swift-test.txt" "$EVIDENCE_DIR/validation-result.txt"

capture() {
    output=$1
    shift
    raw_output=$(/usr/bin/mktemp "/private/tmp/TidyDropEvidence.capture.XXXXXX")
    capture_exit=0
    "$@" >"$raw_output" 2>&1 || capture_exit=$?
    sanitize_evidence_file "$raw_output"
    /bin/mv -f "$raw_output" "$output"
    /bin/cat "$output"
    [ "$capture_exit" -eq 0 ] || return "$capture_exit"
}

sanitize_evidence_file() {
    evidence_file=$1
    sanitized_file="$evidence_file.sanitized.$$"
    /usr/bin/awk -v project_root="$PROJECT_ROOT" -v user_home="$HOME" '
        function replace_literal(text, needle, replacement, prefix, suffix, position) {
            if (needle == "") return text
            while ((position = index(text, needle)) != 0) {
                prefix = substr(text, 1, position - 1)
                suffix = substr(text, position + length(needle))
                text = prefix replacement suffix
            }
            return text
        }
        {
            line = replace_literal($0, project_root, "<repository-root>")
            line = replace_literal(line, user_home, "~")
            print line
        }
    ' "$evidence_file" >"$sanitized_file"
    /bin/mv -f "$sanitized_file" "$evidence_file"
}

for existing_evidence in "$EVIDENCE_DIR"/*.txt "$EVIDENCE_DIR"/*.md; do
    [ -f "$existing_evidence" ] || continue
    sanitize_evidence_file "$existing_evidence"
done

{
    printf 'validated_at_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s\n' 'working_directory=<repository-root>'
    printf 'system='; uname -s
    printf 'kernel_release='; uname -r
    printf 'architecture='; uname -m
    if [ -r /etc/os-release ]; then
        /bin/cat /etc/os-release
    fi
    printf '\nSwift:\n'
    swift --version
    printf '\nplutil:\n'
    command -v plutil || true
    plutil -help 2>&1 | sed -n '1,4p' || true
    printf '\nTesting runtime:\ncustom executable; XCTest not required\n'
} >"$EVIDENCE_DIR/environment.txt"
sanitize_evidence_file "$EVIDENCE_DIR/environment.txt"
/bin/cat "$EVIDENCE_DIR/environment.txt"

cd "$PROJECT_ROOT"

capture "$EVIDENCE_DIR/debug-build.txt" swift build -c debug -Xswiftc -warnings-as-errors
DEBUG_BIN_DIR=$(swift build -c debug --show-bin-path)
DEBUG_BINARY="$DEBUG_BIN_DIR/tidydrop"
SELF_TEST_BINARY="$DEBUG_BIN_DIR/tidydrop-self-test"
[ -x "$DEBUG_BINARY" ] || { printf 'FALLO: no existe %s\n' "$DEBUG_BINARY" >&2; exit 1; }
[ -x "$SELF_TEST_BINARY" ] || { printf 'FALLO: no existe %s\n' "$SELF_TEST_BINARY" >&2; exit 1; }

capture "$EVIDENCE_DIR/self-tests.txt" "$SELF_TEST_BINARY"
capture "$EVIDENCE_DIR/security-prototypes.txt" env \
    TIDYDROP_SELF_TEST_BIN="$SELF_TEST_BINARY" \
    "$SCRIPT_DIR/test-security-prototypes.sh"
capture "$EVIDENCE_DIR/doctor.txt" "$SCRIPT_DIR/doctor.sh"
capture "$EVIDENCE_DIR/doctor-tests.txt" "$SCRIPT_DIR/test-doctor.sh"
capture "$EVIDENCE_DIR/folder-chooser.txt" env TIDYDROP_BIN="$DEBUG_BINARY" "$SCRIPT_DIR/test-folder-chooser.sh"
capture "$EVIDENCE_DIR/stability-race.txt" env TIDYDROP_SELF_TEST_BIN="$SELF_TEST_BINARY" "$SCRIPT_DIR/test-stability-race.sh"
capture "$EVIDENCE_DIR/cli-integration.txt" env TIDYDROP_BIN="$DEBUG_BINARY" "$SCRIPT_DIR/test-cli.sh"
AGENT_BINARY="$DEBUG_BIN_DIR/tidydrop-agent"
[ -x "$AGENT_BINARY" ] || { printf 'FALLO: no existe %s\n' "$AGENT_BINARY" >&2; exit 1; }
capture "$EVIDENCE_DIR/event-agent.txt" env \
    TIDYDROP_BIN="$DEBUG_BINARY" \
    TIDYDROP_AGENT_BIN="$AGENT_BINARY" \
    "$SCRIPT_DIR/test-event-agent.sh"
capture "$EVIDENCE_DIR/launchagent-rendering.txt" "$SCRIPT_DIR/test-launchagent.sh"
capture "$EVIDENCE_DIR/uninstall-safety.txt" "$SCRIPT_DIR/test-uninstall.sh"
capture "$EVIDENCE_DIR/demo-dry-run.txt" env TIDYDROP_BIN="$DEBUG_BINARY" "$SCRIPT_DIR/demo.sh"
capture "$EVIDENCE_DIR/release-build.txt" swift build -c release -Xswiftc -warnings-as-errors
capture "$EVIDENCE_DIR/static-audit.txt" "$SCRIPT_DIR/audit-project.sh"
capture "$EVIDENCE_DIR/update-center.txt" "$SCRIPT_DIR/test-update-center.sh"
capture "$EVIDENCE_DIR/release-manifest-foundation.txt" \
    "$SCRIPT_DIR/test-release-manifest-foundation.sh"
capture "$EVIDENCE_DIR/update-staging-foundation.txt" \
    "$SCRIPT_DIR/test-update-staging-foundation.sh"
capture "$EVIDENCE_DIR/update-transport-foundation.txt" \
    "$SCRIPT_DIR/test-update-transport-foundation.sh"
capture "$EVIDENCE_DIR/update-inspection-foundation.txt" \
    "$SCRIPT_DIR/test-update-inspection-foundation.sh"
capture "$EVIDENCE_DIR/update-recovery-foundation.txt" \
    "$SCRIPT_DIR/test-update-recovery-foundation.sh"
capture "$EVIDENCE_DIR/update-bundle-retention-foundation.txt" \
    "$SCRIPT_DIR/test-update-bundle-retention-foundation.sh"
capture "$EVIDENCE_DIR/release-pipeline.txt" "$SCRIPT_DIR/test-release-pipeline.sh"
package_description=$(swift package describe)
printf '%s\n' "$package_description" >"$EVIDENCE_DIR/package-description.txt"
sanitize_evidence_file "$EVIDENCE_DIR/package-description.txt"
/bin/cat "$EVIDENCE_DIR/package-description.txt"
capture "$EVIDENCE_DIR/swift6-build.txt" swift build -c debug \
    -Xswiftc -warnings-as-errors \
    -Xswiftc -swift-version \
    -Xswiftc 6

"$DEBUG_BINARY" print-default-config >"$EVIDENCE_DIR/generated-default-config.json"
if /usr/bin/cmp -s "$PROJECT_ROOT/config/config.example.json" "$EVIDENCE_DIR/generated-default-config.json"; then
    printf '%s\n' 'Default config parity: PASS' | tee "$EVIDENCE_DIR/config-parity.txt"
else
    printf '%s\n' 'Default config parity: FAIL' | tee "$EVIDENCE_DIR/config-parity.txt" >&2
    exit 1
fi

printf '%s\n' 'Project validation: PASS' | tee "$EVIDENCE_DIR/validation-result.txt"

# El manifiesto representa exactamente el árbol que queda después de generar
# toda la evidencia. Se verifica una vez, se conserva el resultado y se
# regenera para incluir también esa evidencia antes de la verificación final.
"$SCRIPT_DIR/update-manifest.sh"
manifest_result=$("$SCRIPT_DIR/verify-manifest.sh")
printf '%s\n' "$manifest_result" >"$EVIDENCE_DIR/manifest-verification.txt"
"$SCRIPT_DIR/update-manifest.sh"
"$SCRIPT_DIR/verify-manifest.sh"
