#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
RESTORATION_SOURCE="$PROJECT_ROOT/Sources/TidyDropUpdateRecovery/DryRunStateRestoration.swift"
JOURNAL_SOURCE="$PROJECT_ROOT/Sources/TidyDropUpdateRecovery/RetainedCurrentBundle.swift"
DATABASE_SOURCE="$PROJECT_ROOT/Sources/TidyDropCore/AgentActivityDatabase.swift"
SELF_TESTS="$PROJECT_ROOT/SelfTests/TidyDropSelfTests/main.swift"

fail() {
    printf '%s\n' "ERROR: $1" >&2
    exit 1
}

test -f "$RESTORATION_SOURCE" || fail "missing dry-run state restoration protocol"

for token in \
    'DryRunStateRestorationProtocol' \
    'stateRestorationStarted' \
    'configurationRestored' \
    'stateRestored' \
    'applyEnabled: false' \
    'AgentActivityDatabase.quiesceForRecoveryReplacement' \
    'AgentActivityDatabase.verifyRecoveryDatabase' \
    'PRAGMA journal_mode=DELETE;' \
    'PRAGMA locking_mode=EXCLUSIVE;' \
    'RENAME_SWAP' \
    'RENAME_EXCL' \
    'RENAME_NOFOLLOW_ANY' \
    'Darwin.renameatx_np' \
    'Darwin.fsync' \
    'preserveSQLiteSidecars' \
    '/private/tmp/TidyDropIntegration.'
do
    /usr/bin/grep -Fq "$token" \
        "$RESTORATION_SOURCE" "$JOURNAL_SOURCE" "$DATABASE_SOURCE" \
        || fail "missing state-restoration control: $token"
done

if /usr/bin/grep -Eq \
    'StewardEngine|undoLatest|TransactionStore|removeItem|(^|[^[:alnum:]_])unlink[[:space:]]*\(|URLSession|SMAppService|launchctl|tccutil|sudo|/Applications' \
    "$RESTORATION_SOURCE"
then
    fail "state restoration crossed into file undo, deletion, network, services, privileges, or installed-app scope"
fi

for shipping_path in \
    "$PROJECT_ROOT/Sources/TidyDrop" \
    "$PROJECT_ROOT/Sources/TidyDropApp" \
    "$PROJECT_ROOT/Sources/TidyDropAgent"
do
    if /usr/bin/grep -R -Eq \
        'import TidyDropUpdateRecovery|DryRunStateRestorationProtocol' \
        "$shipping_path"
    then
        fail "shipping target imports the non-shipping state restoration protocol"
    fi
done

for test_name in \
    testDryRunStateRestorationRestoresStateWithoutUndoReplay \
    testDryRunStateRestorationRecoversEveryInjectedBoundary \
    testDryRunStateRestorationRejectsIncompatibleSchemaBeforeMutation \
    testDryRunStateRestorationRejectsUnsafeDestinationAndBusyDatabase \
    testDryRunStateRestorationWithoutActivityBackupPreservesDerivedState
do
    /usr/bin/grep -Fq "$test_name" "$SELF_TESTS" \
        || fail "missing state-restoration regression: $test_name"
done

printf '%s\n' \
    'Dry-run state restoration: PASS (private tmp only, no undo replay, SQLite schema/integrity bound)'
