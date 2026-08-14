#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SOURCE="$PROJECT_ROOT/Sources/TidyDropUpdateSecurity/ReleaseManifest.swift"
RG=$(command -v rg || true)

[ -n "$RG" ] && [ -x "$RG" ] || {
    printf '%s\n' 'ERROR: rg is required for the release-manifest gate.' >&2
    exit 1
}
[ -f "$SOURCE" ]

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
    "$RG" -F -q "$required" "$SOURCE" || {
        printf 'ERROR: missing release-manifest control: %s\n' "$required" >&2
        exit 1
    }
done

if "$RG" -n 'PrivateKey|rawRepresentation:[[:space:]]*\[[^]]+\]|BEGIN (EC |OPENSSH |)PRIVATE KEY' \
    "$PROJECT_ROOT/Sources/TidyDropUpdateSecurity"; then
    printf '%s\n' 'ERROR: production signing material or private-key code entered product sources.' >&2
    exit 1
fi

if "$RG" -n 'URLSession|https?://|Network\.framework|WebKit' \
    "$PROJECT_ROOT/Sources/TidyDropUpdateSecurity"; then
    printf '%s\n' 'ERROR: the offline manifest verifier gained a network dependency.' >&2
    exit 1
fi

if "$RG" -n 'import TidyDropUpdateSecurity' \
    "$PROJECT_ROOT/Sources/TidyDropApp" \
    "$PROJECT_ROOT/Sources/TidyDropAgent" \
    "$PROJECT_ROOT/Sources/TidyDropCore" \
    "$PROJECT_ROOT/Sources/TidyDrop"; then
    printf '%s\n' 'ERROR: gated verifier foundation was activated in a shipping target.' >&2
    exit 1
fi

"$RG" -q 'name: "TidyDropUpdateSecurity"' "$PROJECT_ROOT/Package.swift"
"$RG" -q '"TidyDropUpdateSecurity"' "$PROJECT_ROOT/Package.swift"
"$RG" -q 'testSignedReleaseManifestVerifiesCanonicalArtifact' \
    "$PROJECT_ROOT/SelfTests/TidyDropSelfTests/main.swift"
"$RG" -q 'testReleaseManifestRejectsWrongKeyAndMalformedSignature' \
    "$PROJECT_ROOT/SelfTests/TidyDropSelfTests/main.swift"

printf '%s\n' 'Signed release-manifest foundation: PASS (offline verifier; production key and activation absent)'
