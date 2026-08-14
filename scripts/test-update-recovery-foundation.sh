#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
RECOVERY_SOURCE="$PROJECT_ROOT/Sources/TidyDropUpdateRecovery/PrivateRecoveryStateSnapshot.swift"
CORE_DATABASE="$PROJECT_ROOT/Sources/TidyDropCore/AgentActivityDatabase.swift"
PACKAGE="$PROJECT_ROOT/Package.swift"

fail() {
    printf '%s\n' "ERROR: $1" >&2
    exit 1
}

test -f "$RECOVERY_SOURCE" || fail "missing private recovery snapshot source"
/usr/bin/grep -q 'name: "TidyDropUpdateRecovery"' "$PACKAGE" \
    || fail "recovery target is not declared"
/usr/bin/grep -q '"TidyDropUpdateRecovery"' "$PACKAGE" \
    || fail "self-tests do not link the recovery target"

for token in \
    'PrivateUpdateRecoverySnapshotBuilder' \
    'AuthenticatedReleaseManifest' \
    'recoveryConfiguration.automation.applyEnabled = false' \
    'sqlite3_backup_init' \
    'PRAGMA integrity_check;' \
    'SQLITE_OPEN_NOFOLLOW' \
    'F_GETPATH' \
    'deviceID == UInt64(sourceMetadata.st_dev)' \
    'inode == UInt64(sourceMetadata.st_ino)' \
    'O_CREAT | O_EXCL' \
    '0o700' \
    '0o600' \
    'Darwin.fsync' \
    'APP_OWNED_UPDATE_RECOVERY_CLEANUP'
do
    /usr/bin/grep -Fq "$token" "$RECOVERY_SOURCE" "$CORE_DATABASE" \
        || fail "missing recovery control: $token"
done

if /usr/bin/grep -Eq \
    'URLSession|https?://|NSWorkspace|SMAppService|hdiutil|codesign|launchctl|tccutil|sudo|/Applications|replaceItem|copyItem|moveItem|renameat' \
    "$RECOVERY_SOURCE"
then
    fail "state snapshot crossed into networking, app replacement, launch, registration, or privileges"
fi
if /usr/bin/grep -q 'ensurePrivateDirectory' "$RECOVERY_SOURCE"; then
    fail "snapshot builder may not create or chmod a caller-supplied recovery parent"
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
    testPrivateRecoverySnapshotPreservesStateAndForcesDryRunBackup \
    testPrivateRecoverySnapshotFaultsLeaveNoPublishedWorkspace \
    testPrivateRecoverySnapshotRejectsSymlinkParentAndDatabase \
    testAgentActivityDatabaseBackupHandlesPhysicalTmpPath
do
    /usr/bin/grep -q "$test_name" "$PROJECT_ROOT/SelfTests/TidyDropSelfTests/main.swift" \
        || fail "missing recovery regression: $test_name"
done

printf '%s\n' 'Private update recovery state snapshot: PASS (dry-run backup, SQLite-consistent, non-shipping)'
