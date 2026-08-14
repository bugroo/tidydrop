#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
SOURCE="$PROJECT_ROOT/Sources/TidyDropUpdateTransport/FixedOriginUpdateTransport.swift"
STAGING="$PROJECT_ROOT/Sources/TidyDropUpdateSecurity/PrivateUpdateStaging.swift"
TESTS="$PROJECT_ROOT/SelfTests/TidyDropSelfTests/main.swift"
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
    'private static let repositoryHost = "github.com"' \
    'private static let assetHost = "release-assets.githubusercontent.com"' \
    'URLSessionConfiguration.ephemeral' \
    'configuration.urlCache = nil' \
    'configuration.httpCookieStorage = nil' \
    'configuration.urlCredentialStorage = nil' \
    'configuration.httpShouldSetCookies = false' \
    'configuration.httpMaximumConnectionsPerHost = 1' \
    'configuration.timeoutIntervalForRequest' \
    'configuration.timeoutIntervalForResource' \
    'configuration.waitsForConnectivity = false' \
    'request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")' \
    'NSURLAuthenticationMethodServerTrust' \
    'completionHandler(.cancelAuthenticationChallenge, nil)' \
    '@_spi(Testing)' \
    'protocolClasses: [AnyClass]' \
    'authenticatedManifest: AuthenticatedReleaseManifest' \
    'artifactDigestMismatch'; do
    search_fixed "$required" "$SOURCE" "$STAGING" || {
        printf 'ERROR: missing authenticated transport control: %s\n' "$required" >&2
        exit 1
    }
done

if search_regex 'NSWorkspace|SMAppService|hdiutil|Process\(|/Applications|replaceItem|moveItem' \
    "$SOURCE"; then
    printf '%s\n' 'ERROR: transport foundation crossed into mounting, extraction, installation, or activation.' >&2
    exit 1
fi

if search_fixed 'URLProtocol.registerClass' "$PROJECT_ROOT/Sources" "$TESTS"; then
    printf '%s\n' 'ERROR: tests can escape the injected URLProtocol boundary and reach global networking.' >&2
    exit 1
fi

if search_regex 'startForTesting|protocolClasses:' \
    "$PROJECT_ROOT/Sources/TidyDropApp" \
    "$PROJECT_ROOT/Sources/TidyDropAgent" \
    "$PROJECT_ROOT/Sources/TidyDropCore" \
    "$PROJECT_ROOT/Sources/TidyDrop"; then
    printf '%s\n' 'ERROR: test-only transport injection reached a shipping target.' >&2
    exit 1
fi

search_fixed 'name: "TidyDropUpdateTransport"' "$PROJECT_ROOT/Package.swift"
search_fixed 'dependencies: ["TidyDropUpdateSecurity"]' "$PROJECT_ROOT/Package.swift"
search_fixed 'import TidyDropUpdateSecurity' "$SOURCE"

for regression in \
    'testPrivateUpdateStagingRejectsDigestMismatchBeforeFinalization' \
    'testFixedOriginUpdateTransportBuildsAndSanitizesOfficialURLs' \
    'testFixedOriginUpdateTransportStreamsAuthenticatedArtifact' \
    'testFixedOriginUpdateTransportRejectsStatusAndCleansStaging' \
    'testFixedOriginUpdateTransportCancellationCleansStaging'; do
    search_fixed "$regression" "$TESTS"
done

printf '%s\n' 'Fixed-origin authenticated update transport: PASS (ephemeral, injected tests, non-shipping)'
