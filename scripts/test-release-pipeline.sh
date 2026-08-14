#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TEST_ROOT=$(/usr/bin/mktemp -d "/private/tmp/TidyDropIntegration.release.XXXXXX")
trap '/bin/rm -rf "$TEST_ROOT"' EXIT HUP INT TERM
APP="$TEST_ROOT/TidyDrop.app"
DEVELOPMENT_APP="$TEST_ROOT/TidyDropDevelopment.app"
DISTRIBUTION_APP="$TEST_ROOT/TidyDropDistribution.app"
ARTIFACTS="$TEST_ROOT/artifacts"

# El parser debe ser válido para el awk BSD incluido en macOS.
/usr/bin/awk 'BEGIN { line="/Applications/Xcode.app/Contents/Developer"; if (line ~ "^/Applications/Xcode") exit 0; exit 1 }'

if "$SCRIPT_DIR/build-universal-app.sh" "$TEST_ROOT/invalid.app" 'invalid bundle id' \
    >"$TEST_ROOT/invalid-bundle.txt" 2>&1; then
    printf '%s\n' 'ERROR: el build aceptó un bundle ID inválido.' >&2
    exit 1
fi

if "$SCRIPT_DIR/build-universal-app.sh" \
    "$TEST_ROOT/invalid-channel.app" \
    'io.github.bugroo.tidydrop' \
    unsafe >"$TEST_ROOT/invalid-channel.txt" 2>&1; then
    printf '%s\n' 'ERROR: el build aceptó un canal de distribución inválido.' >&2
    exit 1
fi
/usr/bin/grep -q 'canal de distribución desconocido' "$TEST_ROOT/invalid-channel.txt"

"$SCRIPT_DIR/build-universal-app.sh" "$APP" 'io.github.bugroo.tidydrop' community
/usr/bin/ditto "$APP" "$DEVELOPMENT_APP"
/usr/bin/ditto "$APP" "$DISTRIBUTION_APP"
/usr/bin/plutil -replace TidyDropDistributionChannel -string development \
    "$DEVELOPMENT_APP/Contents/Info.plist"
/usr/bin/plutil -replace TidyDropBuildIdentity -string '1.1.1-development' \
    "$DEVELOPMENT_APP/Contents/Info.plist"
/usr/bin/plutil -replace TidyDropDistributionChannel -string distribution \
    "$DISTRIBUTION_APP/Contents/Info.plist"
/usr/bin/plutil -replace TidyDropBuildIdentity -string '1.1.1-distribution' \
    "$DISTRIBUTION_APP/Contents/Info.plist"

if "$SCRIPT_DIR/verify-release.sh" "$APP" community \
    >"$TEST_ROOT/unsigned-community-rejection.txt" 2>&1; then
    printf '%s\n' 'ERROR: Community Preview aceptó un bundle sin firma.' >&2
    exit 1
fi

"$SCRIPT_DIR/sign-app.sh" "$APP" --adhoc
"$SCRIPT_DIR/sign-app.sh" "$DEVELOPMENT_APP" --adhoc
"$SCRIPT_DIR/sign-app.sh" "$DISTRIBUTION_APP" --adhoc
"$SCRIPT_DIR/verify-release.sh" "$APP" community
"$SCRIPT_DIR/verify-release.sh" "$DEVELOPMENT_APP" development

if /usr/bin/otool -L "$APP/Contents/Resources/tidydrop-agent" \
    | /usr/bin/grep -E 'AppKit|SwiftUI|WebKit' >/dev/null 2>&1; then
    printf '%s\n' 'ERROR: el agente mínimo enlaza un framework de UI o WebKit.' >&2
    exit 1
fi
/usr/bin/otool -L "$APP/Contents/MacOS/TidyDropApp" | /usr/bin/grep -q 'AppKit.framework'
/usr/bin/otool -L "$APP/Contents/MacOS/TidyDropApp" | /usr/bin/grep -q 'ServiceManagement.framework'

/bin/mkdir -p "$TEST_ROOT/AgentSource" "$TEST_ROOT/AgentState" "$TEST_ROOT/AgentLogs"
AGENT_CONFIG="$TEST_ROOT/agent-config.json"
/bin/cp "$SCRIPT_DIR/../config/config.example.json" "$AGENT_CONFIG"
/usr/bin/plutil -replace paths.source_directory -string "$TEST_ROOT/AgentSource" "$AGENT_CONFIG"
/usr/bin/plutil -replace paths.destination_root -string "$TEST_ROOT/AgentSource" "$AGENT_CONFIG"
/usr/bin/plutil -replace paths.state_directory -string "$TEST_ROOT/AgentState" "$AGENT_CONFIG"
/usr/bin/plutil -replace paths.log_directory -string "$TEST_ROOT/AgentLogs" "$AGENT_CONFIG"
/usr/bin/plutil -replace automation.apply_enabled -bool false "$AGENT_CONFIG"
"$APP/Contents/Resources/tidydrop-agent" --config "$AGENT_CONFIG"
[ "$(/usr/bin/plutil -extract outcome raw -o - "$TEST_ROOT/AgentState/last-scheduled-run.json")" = 'success' ]
[ "$(/usr/bin/plutil -extract mode raw -o - "$TEST_ROOT/AgentState/last-scheduled-run.json")" = 'dry-run' ]
[ "$(/usr/bin/plutil -extract moved raw -o - "$TEST_ROOT/AgentState/last-scheduled-run.json")" = '0' ]
[ "$(/usr/bin/plutil -extract errors raw -o - "$TEST_ROOT/AgentState/last-scheduled-run.json")" = '0' ]

if TIDYDROP_RELEASE_BUNDLE_ID='bad bundle id' \
   TIDYDROP_RELEASE_TEAM_ID='ABCDE12345' \
   "$SCRIPT_DIR/verify-release.sh" "$DISTRIBUTION_APP" distribution >"$TEST_ROOT/bundle-id-rejection.txt" 2>&1; then
    printf '%s\n' 'ERROR: el gate distribution aceptó un bundle ID esperado inválido.' >&2
    exit 1
fi
/usr/bin/grep -q 'bundle ID esperado inválido' "$TEST_ROOT/bundle-id-rejection.txt"

if TIDYDROP_RELEASE_BUNDLE_ID='io.github.bugroo.tidydrop' \
   TIDYDROP_RELEASE_TEAM_ID='.*' \
   "$SCRIPT_DIR/verify-release.sh" "$DISTRIBUTION_APP" distribution >"$TEST_ROOT/team-id-rejection.txt" 2>&1; then
    printf '%s\n' 'ERROR: el gate distribution aceptó un Team ID inválido.' >&2
    exit 1
fi
/usr/bin/grep -q 'Team ID inválido' "$TEST_ROOT/team-id-rejection.txt"

if TIDYDROP_RELEASE_BUNDLE_ID='io.github.bugroo.tidydrop' \
   TIDYDROP_RELEASE_TEAM_ID='ABCDE12345' \
   "$SCRIPT_DIR/verify-release.sh" "$DISTRIBUTION_APP" distribution >"$TEST_ROOT/distribution-rejection.txt" 2>&1; then
    printf '%s\n' 'ERROR: el gate distribution aceptó una firma ad hoc.' >&2
    exit 1
fi
if TIDYDROP_RELEASE_BUNDLE_ID='io.github.bugroo.tidydrop' \
   TIDYDROP_RELEASE_TEAM_ID='ABCDE12345' \
   "$SCRIPT_DIR/notarize-app.sh" "$DISTRIBUTION_APP" --keychain-profile 'must-not-be-used' \
    >"$TEST_ROOT/notary-rejection.txt" 2>&1; then
    printf '%s\n' 'ERROR: la notarización aceptó un bundle ad hoc.' >&2
    exit 1
fi
/usr/bin/grep -q 'falta firma Developer ID Application' "$TEST_ROOT/notary-rejection.txt"

/bin/mkdir -p "$TEST_ROOT/real-artifacts"
/bin/ln -s "$TEST_ROOT/real-artifacts" "$TEST_ROOT/artifacts-link"
if "$SCRIPT_DIR/package-release.sh" "$APP" "$TEST_ROOT/artifacts-link" community \
    >"$TEST_ROOT/output-symlink-rejection.txt" 2>&1; then
    printf '%s\n' 'ERROR: el empaquetador siguió un directorio de salida symlink.' >&2
    exit 1
fi
/usr/bin/grep -q 'no puede ser un symlink' "$TEST_ROOT/output-symlink-rejection.txt"

"$SCRIPT_DIR/package-release.sh" "$APP" "$ARTIFACTS" community
VERSION=$(/bin/cat "$SCRIPT_DIR/../VERSION")
[ -f "$ARTIFACTS/TidyDrop-$VERSION-community-preview-macos-universal.dmg" ]
[ -f "$ARTIFACTS/TidyDrop-$VERSION-community-preview-macos-universal.sha256" ]

/bin/mkdir -p "$TEST_ROOT/development-artifacts"
"$SCRIPT_DIR/package-release.sh" \
    "$DEVELOPMENT_APP" \
    "$TEST_ROOT/development-artifacts" \
    development
[ -f "$TEST_ROOT/development-artifacts/TidyDrop-$VERSION-macos-universal-development.dmg" ]

if "$SCRIPT_DIR/notarize-dmg.sh" \
    "$ARTIFACTS/TidyDrop-$VERSION-community-preview-macos-universal.dmg" \
    --keychain-profile 'must-not-be-used' \
    >"$TEST_ROOT/dmg-notary-rejection.txt" 2>&1; then
    printf '%s\n' 'ERROR: notarize-dmg aceptó un DMG ad hoc.' >&2
    exit 1
fi
/usr/bin/grep -q 'no tiene Developer ID Application' "$TEST_ROOT/dmg-notary-rejection.txt"

"$SCRIPT_DIR/test-community-preview-workflow.sh"
printf '%s\n' 'Release pipeline tests: PASS (development + Community Preview DMGs; distribution fail-closed)'
