#!/bin/sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
PROTOCOL_SOURCE="$PROJECT_ROOT/Sources/TidyDropUpdateRecovery/DestinationVolumeReplacement.swift"
HELPER_SOURCE="$PROJECT_ROOT/Sources/TidyDropRecoveryHelper/main.swift"
SELF_TESTS="$PROJECT_ROOT/SelfTests/TidyDropSelfTests/main.swift"
PACKAGE="$PROJECT_ROOT/Package.swift"
UNIVERSAL_BUILD="$PROJECT_ROOT/scripts/build-universal-app.sh"

fail() {
    printf '%s\n' "ERROR: $1" >&2
    exit 1
}

test -f "$PROTOCOL_SOURCE" || fail "missing destination-volume replacement protocol"
test -f "$HELPER_SOURCE" || fail "missing external recovery helper"

for token in \
    'tidydrop-recovery-helper' \
    'TidyDropRecoveryHelper' \
    'DestinationVolumeReplacementProtocol' \
    'RENAME_SWAP' \
    'RENAME_NOFOLLOW_ANY' \
    'Darwin.renameatx_np' \
    'Darwin.fsync' \
    'candidateContainerIdentity' \
    'EntryIdentity' \
    'apply_enabled=false' \
    '/private/tmp/TidyDropIntegration.'
do
    /usr/bin/grep -Fq "$token" "$PROTOCOL_SOURCE" "$HELPER_SOURCE" "$PACKAGE" \
        || fail "missing external-recovery control: $token"
done

/usr/bin/grep -Fq 'private static let installedBundleName = "TidyDrop.app"' \
    "$PROTOCOL_SOURCE" || fail "installed swap operand is not a fixed component"
/usr/bin/grep -Fq 'return ".tidydrop-replacement-\(transactionID)"' \
    "$PROTOCOL_SOURCE" || fail "candidate container is not transaction-bound"
if /usr/bin/grep -Fq 'RENAME_RESOLVE_BENEATH' "$PROTOCOL_SOURCE"; then
    /usr/bin/grep -Fq 'macOS 15 SDK does not expose it' "$PROTOCOL_SOURCE" \
        || fail "RENAME_RESOLVE_BENEATH use is not SDK-portable"
fi

if /usr/bin/grep -Eq \
    'URLSession|https?://|SMAppService|launchctl|tccutil|sudo|/Applications|FileManager\.default\.(copyItem|moveItem|removeItem)' \
    "$PROTOCOL_SOURCE" "$HELPER_SOURCE"
then
    fail "external recovery crossed into network, installed-app scope, services, privileges, or path copy"
fi

if /usr/bin/grep -Fq 'tidydrop-recovery-helper' "$UNIVERSAL_BUILD"; then
    fail "non-shipping recovery helper was added to the distributable app builder"
fi

for shipping_path in \
    "$PROJECT_ROOT/Sources/TidyDrop" \
    "$PROJECT_ROOT/Sources/TidyDropApp" \
    "$PROJECT_ROOT/Sources/TidyDropAgent" \
    "$PROJECT_ROOT/Sources/TidyDropCore"
do
    if /usr/bin/grep -R -Eq 'import TidyDropUpdateRecovery|DestinationVolumeReplacement' "$shipping_path"; then
        fail "shipping target imports the non-shipping replacement protocol"
    fi
done

for test_name in \
    testDestinationVolumeReplacementAtomicallyInstallsAndRollsBack \
    testDestinationVolumeReplacementRecoversBothInterruptedSwaps \
    testDestinationVolumeReplacementResumesBeforeEitherSwap \
    testDestinationVolumeReplacementRejectsInstalledScopeAndSymlinkCandidate
do
    /usr/bin/grep -q "$test_name" "$SELF_TESTS" \
        || fail "missing external-recovery regression: $test_name"
done

printf '%s\n' \
    'External recovery helper and atomic swap: PASS (private tmp only, non-shipping)'
