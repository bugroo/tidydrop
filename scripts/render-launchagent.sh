#!/bin/sh
set -eu

if [ "$#" -ne 5 ]; then
    printf 'Uso: %s SALIDA EJECUTABLE CONFIG INTERVAL HOME\n' "$0" >&2
    exit 2
fi

OUTPUT=$1
EXECUTABLE=$2
CONFIG_FILE=$3
INTERVAL=$4
HOME_VALUE=$5
LABEL='com.local.tidydrop'

case "$INTERVAL" in
    ''|*[!0-9]*)
        printf '%s\n' 'ERROR: INTERVAL debe ser un entero.' >&2
        exit 2
        ;;
esac
if [ "$INTERVAL" -lt 15 ]; then
    printf '%s\n' 'ERROR: INTERVAL debe ser >= 15.' >&2
    exit 2
fi

PLUTIL=${PLUTIL:-}
if [ -z "$PLUTIL" ]; then
    PLUTIL=$(command -v plutil 2>/dev/null || true)
fi
[ -n "$PLUTIL" ] && [ -x "$PLUTIL" ] || {
    printf '%s\n' 'ERROR: plutil no está disponible.' >&2
    exit 1
}

OUTPUT_PARENT=$(dirname -- "$OUTPUT")
/bin/mkdir -p "$OUTPUT_PARENT"
TEMP_PLIST="$OUTPUT.new.$$"
trap '/bin/rm -f "$TEMP_PLIST"' EXIT HUP INT TERM
/bin/rm -f "$TEMP_PLIST"

"$PLUTIL" -create xml1 "$TEMP_PLIST"
"$PLUTIL" -insert Label -string "$LABEL" "$TEMP_PLIST"
"$PLUTIL" -insert ProgramArguments -array "$TEMP_PLIST"
"$PLUTIL" -insert ProgramArguments -string "$EXECUTABLE" -append "$TEMP_PLIST"
"$PLUTIL" -insert ProgramArguments -string 'run' -append "$TEMP_PLIST"
"$PLUTIL" -insert ProgramArguments -string '--scheduled' -append "$TEMP_PLIST"
"$PLUTIL" -insert ProgramArguments -string '--config' -append "$TEMP_PLIST"
"$PLUTIL" -insert ProgramArguments -string "$CONFIG_FILE" -append "$TEMP_PLIST"
"$PLUTIL" -insert RunAtLoad -bool true "$TEMP_PLIST"
"$PLUTIL" -insert StartInterval -integer "$INTERVAL" "$TEMP_PLIST"
"$PLUTIL" -insert ProcessType -string 'Background' "$TEMP_PLIST"
"$PLUTIL" -insert ThrottleInterval -integer 10 "$TEMP_PLIST"
"$PLUTIL" -insert Nice -integer 10 "$TEMP_PLIST"
"$PLUTIL" -insert Umask -integer 63 "$TEMP_PLIST"
"$PLUTIL" -insert LimitLoadToSessionType -string 'Aqua' "$TEMP_PLIST"
"$PLUTIL" -insert AssociatedBundleIdentifiers -array "$TEMP_PLIST"
"$PLUTIL" -insert AssociatedBundleIdentifiers -string "$LABEL" -append "$TEMP_PLIST"
"$PLUTIL" -insert EnvironmentVariables -dictionary "$TEMP_PLIST"
"$PLUTIL" -insert EnvironmentVariables.HOME -string "$HOME_VALUE" "$TEMP_PLIST"
"$PLUTIL" -insert EnvironmentVariables.PATH -string '/usr/bin:/bin:/usr/sbin:/sbin' "$TEMP_PLIST"
"$PLUTIL" -lint "$TEMP_PLIST"
/bin/mv "$TEMP_PLIST" "$OUTPUT"
/bin/chmod 600 "$OUTPUT"
trap - EXIT HUP INT TERM
