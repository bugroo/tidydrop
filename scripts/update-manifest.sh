#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
TEMP_ROOT=$(/usr/bin/mktemp -d "/private/tmp/TidyDropManifest.update.XXXXXX")
trap '/bin/rm -rf "$TEMP_ROOT"' EXIT HUP INT TERM

PATHS_FILE="$TEMP_ROOT/paths.txt"
NEXT_MANIFEST="$TEMP_ROOT/MANIFEST.sha256"

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
    | LC_ALL=C /usr/bin/sort >"$PATHS_FILE"

while IFS= read -r distributed_file; do
    [ -n "$distributed_file" ] || continue
    /usr/bin/shasum -a 256 "$distributed_file" >>"$NEXT_MANIFEST"
done <"$PATHS_FILE"

/bin/chmod 600 "$NEXT_MANIFEST"
/bin/mv -f "$NEXT_MANIFEST" "$PROJECT_ROOT/MANIFEST.sha256"
/bin/chmod 644 "$PROJECT_ROOT/MANIFEST.sha256"
printf 'Manifest actualizado: %s archivos\n' "$(/usr/bin/wc -l <"$PROJECT_ROOT/MANIFEST.sha256" | /usr/bin/tr -d ' ')"
