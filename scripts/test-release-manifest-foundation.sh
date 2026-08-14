#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SOURCE="$PROJECT_ROOT/Sources/TidyDropUpdateSecurity/ReleaseManifest.swift"
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
    'Curve25519.Signing.PublicKey' \
    'decodeCanonical' \
    'O_NOFOLLOW' \
    'S_IFREG' \
    'Darwin.fstat' \
    'SHA256()' \
    'artifactChangedDuringVerification' \
    'wrongBundleIdentifier' \
    'wrongArtifactName' \
    'downgrade' \
    'replay'; do
    search_fixed "$required" "$SOURCE" || {
        printf 'ERROR: missing release-manifest control: %s\n' "$required" >&2
        exit 1
    }
done

if search_regex 'PrivateKey|rawRepresentation:[[:space:]]*\[[^]]+\]|BEGIN ((EC|OPENSSH) )?PRIVATE KEY' \
    "$PROJECT_ROOT/Sources/TidyDropUpdateSecurity"; then
    printf '%s\n' 'ERROR: production signing material or private-key code entered product sources.' >&2
    exit 1
fi

if search_regex 'URLSession|https?://|Network\.framework|WebKit' \
    "$PROJECT_ROOT/Sources/TidyDropUpdateSecurity"; then
    printf '%s\n' 'ERROR: the offline manifest verifier gained a network dependency.' >&2
    exit 1
fi

if search_regex 'import TidyDropUpdateSecurity' \
    "$PROJECT_ROOT/Sources/TidyDropApp" \
    "$PROJECT_ROOT/Sources/TidyDropAgent" \
    "$PROJECT_ROOT/Sources/TidyDropCore" \
    "$PROJECT_ROOT/Sources/TidyDrop"; then
    printf '%s\n' 'ERROR: gated verifier foundation was activated in a shipping target.' >&2
    exit 1
fi

search_fixed 'name: "TidyDropUpdateSecurity"' "$PROJECT_ROOT/Package.swift"
search_fixed '"TidyDropUpdateSecurity"' "$PROJECT_ROOT/Package.swift"
search_fixed 'testSignedReleaseManifestVerifiesCanonicalArtifact' \
    "$PROJECT_ROOT/SelfTests/TidyDropSelfTests/main.swift"
search_fixed 'testReleaseManifestRejectsWrongKeyAndMalformedSignature' \
    "$PROJECT_ROOT/SelfTests/TidyDropSelfTests/main.swift"

printf '%s\n' 'Signed release-manifest foundation: PASS (offline verifier; production key and activation absent)'
