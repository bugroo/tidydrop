#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TEST_ROOT=$(/usr/bin/mktemp -d "/private/tmp/TidyDropIntegration.release.XXXXXX")
trap '/bin/rm -rf "$TEST_ROOT"' EXIT HUP INT TERM
APP="$TEST_ROOT/TidyDrop.app"
ARTIFACTS="$TEST_ROOT/artifacts"

# El parser debe ser válido para el awk BSD incluido en macOS.
/usr/bin/awk 'BEGIN { line="/Applications/Xcode.app/Contents/Developer"; if (line ~ "^/Applications/Xcode") exit 0; exit 1 }'

if "$SCRIPT_DIR/build-universal-app.sh" "$TEST_ROOT/invalid.app" 'invalid bundle id' \
    >"$TEST_ROOT/invalid-bundle.txt" 2>&1; then
    printf '%s\n' 'ERROR: el build aceptó un bundle ID inválido.' >&2
    exit 1
fi

"$SCRIPT_DIR/build-universal-app.sh" "$APP" 'invalid.test.tidydrop'
"$SCRIPT_DIR/sign-app.sh" "$APP" --adhoc
"$SCRIPT_DIR/verify-release.sh" "$APP" development

if TIDYDROP_RELEASE_BUNDLE_ID='bad bundle id' \
   TIDYDROP_RELEASE_TEAM_ID='ABCDE12345' \
   "$SCRIPT_DIR/verify-release.sh" "$APP" distribution >"$TEST_ROOT/bundle-id-rejection.txt" 2>&1; then
    printf '%s\n' 'ERROR: el gate distribution aceptó un bundle ID esperado inválido.' >&2
    exit 1
fi
/usr/bin/grep -q 'bundle ID esperado inválido' "$TEST_ROOT/bundle-id-rejection.txt"

if TIDYDROP_RELEASE_BUNDLE_ID='invalid.test.tidydrop' \
   TIDYDROP_RELEASE_TEAM_ID='.*' \
   "$SCRIPT_DIR/verify-release.sh" "$APP" distribution >"$TEST_ROOT/team-id-rejection.txt" 2>&1; then
    printf '%s\n' 'ERROR: el gate distribution aceptó un Team ID inválido.' >&2
    exit 1
fi
/usr/bin/grep -q 'Team ID inválido' "$TEST_ROOT/team-id-rejection.txt"

if TIDYDROP_RELEASE_BUNDLE_ID='invalid.test.tidydrop' \
   TIDYDROP_RELEASE_TEAM_ID='ABCDE12345' \
   "$SCRIPT_DIR/verify-release.sh" "$APP" distribution >"$TEST_ROOT/distribution-rejection.txt" 2>&1; then
    printf '%s\n' 'ERROR: el gate distribution aceptó una firma ad hoc.' >&2
    exit 1
fi
if TIDYDROP_RELEASE_BUNDLE_ID='invalid.test.tidydrop' \
   TIDYDROP_RELEASE_TEAM_ID='ABCDE12345' \
   "$SCRIPT_DIR/notarize-app.sh" "$APP" --keychain-profile 'must-not-be-used' \
    >"$TEST_ROOT/notary-rejection.txt" 2>&1; then
    printf '%s\n' 'ERROR: la notarización aceptó un bundle ad hoc.' >&2
    exit 1
fi
/usr/bin/grep -q 'falta firma Developer ID Application' "$TEST_ROOT/notary-rejection.txt"

/bin/mkdir -p "$TEST_ROOT/real-artifacts"
/bin/ln -s "$TEST_ROOT/real-artifacts" "$TEST_ROOT/artifacts-link"
if "$SCRIPT_DIR/package-release.sh" "$APP" "$TEST_ROOT/artifacts-link" development \
    >"$TEST_ROOT/output-symlink-rejection.txt" 2>&1; then
    printf '%s\n' 'ERROR: el empaquetador siguió un directorio de salida symlink.' >&2
    exit 1
fi
/usr/bin/grep -q 'no puede ser un symlink' "$TEST_ROOT/output-symlink-rejection.txt"

"$SCRIPT_DIR/package-release.sh" "$APP" "$ARTIFACTS" development
[ -f "$ARTIFACTS/TidyDrop-1.0.2-macos-universal-development.zip" ]
[ -f "$ARTIFACTS/TidyDrop-1.0.2-macos-universal-development.sha256" ]

printf '%s\n' 'Release pipeline tests: PASS (Universal 2 + hardened ad hoc; distribution fail-closed)'
