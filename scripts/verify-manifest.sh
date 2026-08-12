#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
MANIFEST="$PROJECT_ROOT/MANIFEST.sha256"
TEMP_ROOT=$(/usr/bin/mktemp -d "/private/tmp/TidyDropManifest.verify.XXXXXX")
trap '/bin/rm -rf "$TEMP_ROOT"' EXIT HUP INT TERM

EXPECTED_PATHS="$TEMP_ROOT/expected-paths.txt"
MANIFEST_PATHS="$TEMP_ROOT/manifest-paths.txt"

[ -f "$MANIFEST" ] && [ ! -L "$MANIFEST" ] || {
    printf '%s\n' 'FALLO: MANIFEST.sha256 falta o es un symlink.' >&2
    exit 1
}

cd "$PROJECT_ROOT"

unsafe_symlinks=$(
    /usr/bin/find . -type l \
        ! -path './.git/*' \
        ! -path './.build/*' \
        ! -path './.swiftpm/*' \
        -print
)
if [ -n "$unsafe_symlinks" ]; then
    printf '%s\n' 'FALLO: la distribución contiene symlinks:' >&2
    printf '%s\n' "$unsafe_symlinks" >&2
    exit 1
fi

/usr/bin/find . -type f \
    ! -path './.git/*' \
    ! -path './.build/*' \
    ! -path './.swiftpm/*' \
    ! -name '.DS_Store' \
    ! -name 'MANIFEST.sha256' \
    ! -name 'TidyDrop-*.zip' \
    ! -name 'TidyDrop-*.sha256' \
    ! -name 'TidyDrop-*-validation.txt' \
    -print \
    | /usr/bin/sed 's#^\./##' \
    | LC_ALL=C /usr/bin/sort >"$EXPECTED_PATHS"

/usr/bin/sed -E 's/^[0-9a-f]{64}  //' "$MANIFEST" \
    | LC_ALL=C /usr/bin/sort >"$MANIFEST_PATHS"

if ! /usr/bin/cmp -s "$EXPECTED_PATHS" "$MANIFEST_PATHS"; then
    printf '%s\n' 'FALLO: el inventario de MANIFEST.sha256 no coincide con la distribución.' >&2
    /usr/bin/diff -u "$MANIFEST_PATHS" "$EXPECTED_PATHS" >&2 || true
    exit 1
fi

/usr/bin/shasum -a 256 -c "$MANIFEST"
printf 'Manifest verificado: %s archivos\n' "$(/usr/bin/wc -l <"$MANIFEST" | /usr/bin/tr -d ' ')"
