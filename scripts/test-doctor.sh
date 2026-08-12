#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(mktemp -d "/private/tmp/TidyDropIntegration.doctor-tests.XXXXXX")
trap '/bin/rm -rf "$ROOT"' EXIT HUP INT TERM
TEST_HOME="$ROOT/Home"
/bin/mkdir -p "$TEST_HOME/Downloads"

OUTPUT="$ROOT/doctor.txt"
HOME="$TEST_HOME" "$SCRIPT_DIR/doctor.sh" >"$OUTPUT" 2>&1
/usr/bin/grep -q 'Compilación Swift/Foundation con SDK explícito.*\[OK\]' "$OUTPUT"
/usr/bin/grep -q 'Ejecución del probe Swift/Foundation.*\[OK\]' "$OUTPUT"
/usr/bin/grep -q 'SDK macOS: .*\[OK\]' "$OUTPUT"
/usr/bin/grep -q 'Versión SDK macOS: .*\[OK\]' "$OUTPUT"
/usr/bin/grep -q 'Proyecto sin XCTest; Xcode completo no es necesario.*\[OK\]' "$OUTPUT"

FAKE_XCRUN="$ROOT/xcrun-no-sdk"
cat >"$FAKE_XCRUN" <<'SH'
#!/bin/sh
case "$*" in
  *'--show-sdk-path'*) exit 1 ;;
  *'--show-sdk-version'*) printf '%s\n' '26.5' ;;
  *'--find swiftc'*) /usr/bin/xcrun --sdk macosx --find swiftc ;;
  *'--find swift'*) /usr/bin/xcrun --sdk macosx --find swift ;;
  *) exec /usr/bin/xcrun "$@" ;;
esac
SH
/bin/chmod 700 "$FAKE_XCRUN"
if HOME="$TEST_HOME" TIDYDROP_XCRUN_BIN="$FAKE_XCRUN" "$SCRIPT_DIR/doctor.sh" >"$ROOT/no-sdk.txt" 2>&1; then
    printf '%s\n' 'ERROR: doctor debería fallar claramente sin SDK.' >&2
    exit 1
fi
/usr/bin/grep -q 'SDK macOS disponible mediante xcrun.*\[FALLO\]' "$ROOT/no-sdk.txt"
/usr/bin/grep -q 'Resultado: .* fallo(s)' "$ROOT/no-sdk.txt"

printf '%s\n' 'Doctor CLT/SDK tests: PASS'
