#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SOURCE="$PROJECT_ROOT/Sources/TidyDropUpdateInspection/SafeUpdateBundleInspector.swift"
TESTS="$PROJECT_ROOT/SelfTests/TidyDropSelfTests/main.swift"
PACKAGE="$PROJECT_ROOT/Package.swift"
RELEASE_PIPELINE="$PROJECT_ROOT/scripts/test-release-pipeline.sh"
RG=$(command -v rg || true)

[ -f "$SOURCE" ]

search_fixed() {
    needle=$1
    shift
    if [ -n "$RG" ] && [ -x "$RG" ]; then
        "$RG" -F -q -- "$needle" "$@"
    else
        /usr/bin/grep -R -F -q -- "$needle" "$@"
    fi
}

search_regex() {
    pattern=$1
    shift
    if [ -n "$RG" ] && [ -x "$RG" ]; then
        "$RG" -n -- "$pattern" "$@"
    else
        /usr/bin/grep -R -n -E -- "$pattern" "$@"
    fi
}

for required in \
    'private static let hdiutilURL = URL(fileURLWithPath: "/usr/bin/hdiutil")' \
    '"verify", verified.artifactURL.path' \
    '"-readonly", "-verify", "-nobrowse", "-noautoopen"' \
    '"-owners", "off", "-mountpoint", mount.url.path' \
    'process.standardInput = FileHandle.nullDevice' \
    'process.standardOutput = FileHandle.nullDevice' \
    'process.standardError = FileHandle.nullDevice' \
    'O_NOFOLLOW' \
    'AT_SYMLINK_NOFOLLOW' \
    'workspaceMetadata.st_mode & 0o777 == 0o700' \
    'artifactMetadata.st_mode & 0o777 == 0o600' \
    'manifest.artifactSHA256' \
    'kSecCSCheckAllArchitectures' \
    'kSecCSStrictValidate' \
    'kSecCSCheckNestedCode' \
    'SecStaticCodeCheckValidity' \
    'private static let requiredResourceExecutables = ["tidydrop", "tidydrop-agent"]' \
    'Set(architectures) == requiredArchitectures' \
    'filesystem.f_flags & UInt32(MNT_RDONLY) != 0' \
    'APP_OWNED_UPDATE_MOUNT_CLEANUP' \
    '@_spi(Testing)'; do
    search_fixed "$required" "$SOURCE" || {
        printf 'ERROR: missing update-inspection control: %s\n' "$required" >&2
        exit 1
    }
done

if search_regex 'NSWorkspace|SMAppService|replaceItem|copyItem|moveItem|openApplication|launchApplication' \
    "$SOURCE"; then
    printf '%s\n' 'ERROR: inspection foundation crossed into application activation or replacement.' >&2
    exit 1
fi

if search_regex 'URLSession|NWConnection|https?://' "$SOURCE"; then
    printf '%s\n' 'ERROR: bundle inspection must remain offline.' >&2
    exit 1
fi

if search_fixed '"-force"' "$SOURCE"; then
    printf '%s\n' 'ERROR: inspection must not force-detach a mounted image.' >&2
    exit 1
fi

if search_regex 'import[[:space:]]+TidyDropUpdateInspection' \
    "$PROJECT_ROOT/Sources/TidyDropApp" \
    "$PROJECT_ROOT/Sources/TidyDropAgent" \
    "$PROJECT_ROOT/Sources/TidyDropCore" \
    "$PROJECT_ROOT/Sources/TidyDrop"; then
    printf '%s\n' 'ERROR: non-shipping inspection reached a shipping target.' >&2
    exit 1
fi

search_fixed 'name: "TidyDropUpdateInspection"' "$PACKAGE"
search_fixed 'dependencies: ["TidyDropUpdateSecurity"]' "$PACKAGE"
search_fixed 'TIDYDROP_INSPECTION_DMG="$COMMUNITY_DMG"' "$RELEASE_PIPELINE"
search_fixed "TIDYDROP_SELF_TEST_FILTER='testSafeUpdateBundleInspectorMountsReadOnlyAndValidatesSignedUniversalApp'" \
    "$RELEASE_PIPELINE"

for regression in \
    'testSafeUpdateBundleInspectorRejectsForgedStagedEvidenceBeforeMount' \
    'testSafeUpdateBundleInspectorMountsReadOnlyAndValidatesSignedUniversalApp' \
    'testMountedUpdateBundleInspectionRejectsUnexpectedRootAndBundleSymlink' \
    'testMountedUpdateBundleInspectionRejectsWrongIdentityThinBinaryAndTampering'; do
    search_fixed "$regression" "$TESTS"
done

printf '%s\n' 'Safe authenticated DMG and bundle inspection: PASS (read-only, bounded, non-shipping)'
