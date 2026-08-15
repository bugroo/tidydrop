#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
RETENTION_SOURCE="$PROJECT_ROOT/Sources/TidyDropUpdateRecovery/RetainedCurrentBundle.swift"
INSPECTION_SOURCE="$PROJECT_ROOT/Sources/TidyDropUpdateInspection/SafeUpdateBundleInspector.swift"
SELF_TESTS="$PROJECT_ROOT/SelfTests/TidyDropSelfTests/main.swift"

fail() {
    printf '%s\n' "ERROR: $1" >&2
    exit 1
}

test -f "$RETENTION_SOURCE" || fail "missing retained-current-bundle source"

for token in \
    'CurrentBundleRetentionBuilder' \
    'SafeUpdateBundleInspector.inspectExistingBundle' \
    'sourceInspectionAfterCopy' \
    'Darwin.fcopyfile' \
    'COPYFILE_ALL' \
    'O_NOFOLLOW' \
    'AT_SYMLINK_NOFOLLOW' \
    'sameStableFile' \
    'retainedBundleTreeSHA256' \
    'stateSnapshotManifestSHA256' \
    'recoveryConfiguration.automation.applyEnabled = false' \
    'ExternalRecoveryState' \
    'afterNextJournalSynchronization' \
    'APP_OWNED_RECOVERY_JOURNAL_RENAME' \
    'Darwin.fsync'
do
    /usr/bin/grep -Fq "$token" "$RETENTION_SOURCE" \
        "$INSPECTION_SOURCE" \
        "$PROJECT_ROOT/Sources/TidyDropUpdateRecovery/PrivateRecoveryStateSnapshot.swift" \
        || fail "missing bundle-retention control: $token"
done

if /usr/bin/grep -Eq \
    'URLSession|https?://|NSWorkspace|SMAppService|hdiutil|launchctl|tccutil|sudo|/Applications|replaceItem|openApplication|launchApplication' \
    "$RETENTION_SOURCE"
then
    fail "bundle retention crossed into network, replacement, launch, registration, or privileges"
fi

if /usr/bin/grep -Eq 'FileManager\.default\.(copyItem|moveItem|removeItem)' "$RETENTION_SOURCE"; then
    fail "bundle retention bypasses descriptor-bound copy and exact cleanup"
fi

for shipping_path in \
    "$PROJECT_ROOT/Sources/TidyDrop" \
    "$PROJECT_ROOT/Sources/TidyDropApp" \
    "$PROJECT_ROOT/Sources/TidyDropAgent" \
    "$PROJECT_ROOT/Sources/TidyDropCore"
do
    if /usr/bin/grep -R -Eq 'import TidyDropUpdateRecovery' "$shipping_path"; then
        fail "shipping target imports the non-shipping recovery foundation"
    fi
done

for test_name in \
    testCurrentBundleRetentionPreservesVerifiedUniversalAppAndPublishesDryRunJournal \
    testCurrentBundleRetentionFaultsCleanOnlyRetainedArtifacts \
    testCurrentBundleRetentionRejectsSymlinkAndTamperedRetainedTree \
    testExternalRecoveryJournalRecoversSynchronizedNextStateAndRejectsReplay \
    testExistingBundleInspectorRejectsWrongVersionAndBundleSymlink
do
    /usr/bin/grep -q "$test_name" "$SELF_TESTS" \
        || fail "missing bundle-retention regression: $test_name"
done

printf '%s\n' \
    'Retained current bundle and external recovery journal: PASS (descriptor-bound, non-shipping)'
