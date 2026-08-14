#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SOURCE="$PROJECT_ROOT/Sources/TidyDropUpdateSecurity/PrivateUpdateStaging.swift"
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
    'authenticatedManifest: AuthenticatedReleaseManifest' \
    'O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW' \
    'O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW' \
    'Darwin.openat' \
    'Darwin.fstat' \
    'Darwin.fstatfs' \
    'Darwin.renameatx_np' \
    'RENAME_EXCL' \
    'AT_SYMLINK_NOFOLLOW' \
    'APP_OWNED_UPDATE_STAGING_CLEANUP' \
    '".\(manifest.artifactName).partial"' \
    'diskFull(afterBytes:' \
    'state = .cancelled'; do
    search_fixed "$required" "$SOURCE" || {
        printf 'ERROR: missing private-staging control: %s\n' "$required" >&2
        exit 1
    }
done

if search_regex 'URLSession|https?://|NSWorkspace|SMAppService|hdiutil|Process\(|/Applications|replaceItem|moveItem' \
    "$SOURCE"; then
    printf '%s\n' 'ERROR: staging foundation crossed into network, mounting, installation, or agent control.' >&2
    exit 1
fi

if search_regex 'import TidyDropUpdateSecurity' \
    "$PROJECT_ROOT/Sources/TidyDropApp" \
    "$PROJECT_ROOT/Sources/TidyDropAgent" \
    "$PROJECT_ROOT/Sources/TidyDropCore" \
    "$PROJECT_ROOT/Sources/TidyDrop"; then
    printf '%s\n' 'ERROR: gated staging foundation was activated in a shipping target.' >&2
    exit 1
fi

unsafe_cleanup=$(
    search_regex 'unlinkat' "$SOURCE" \
        | /usr/bin/grep -v 'APP_OWNED_UPDATE_STAGING_CLEANUP' \
        || true
)
if [ -n "$unsafe_cleanup" ]; then
    printf '%s\n' 'ERROR: staging cleanup lacks the exact app-owned marker.' >&2
    printf '%s\n' "$unsafe_cleanup" >&2
    exit 1
fi

for regression in \
    'testPrivateUpdateStagingFinalizesDescriptorBoundArtifact' \
    'testPrivateUpdateStagingRejectsSymlinkAndBroadParent' \
    'testPrivateUpdateStagingBoundsAndCleansPartialWorkspace' \
    'testPrivateUpdateStagingCancellationCleansPartialWorkspace' \
    'testPrivateUpdateStagingDiskFullFaultCleansPartialWorkspace' \
    'testPrivateUpdateStagingNeverOverwritesFinalCollision'; do
    search_fixed "$regression" "$PROJECT_ROOT/SelfTests/TidyDropSelfTests/main.swift"
done

printf '%s\n' 'Private update-staging foundation: PASS (descriptor-bound; no network, mount, install, or activation)'
