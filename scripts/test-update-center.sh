#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CLIENT="$PROJECT_ROOT/Sources/TidyDropApp/UpdateCheckService.swift"
WINDOW="$PROJECT_ROOT/Sources/TidyDropApp/UpdateCenterWindowController.swift"
APP="$PROJECT_ROOT/Sources/TidyDropApp/TidyDropApplication.swift"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

for file in "$CLIENT" "$WINDOW" "$APP"; do
    [ -f "$file" ] && [ ! -L "$file" ] || fail "missing regular Update Center source: $file"
done

/usr/bin/grep -Fq \
    'https://api.github.com/repos/bugroo/tidydrop/releases?per_page=20' \
    "$CLIENT" || fail 'the release API endpoint is not fixed to the official repository'
/usr/bin/grep -Fq 'URLSessionConfiguration.ephemeral' "$CLIENT" \
    || fail 'the update request is not ephemeral'
/usr/bin/grep -Fq 'httpCookieStorage = nil' "$CLIENT" \
    || fail 'cookie storage is not disabled'
/usr/bin/grep -Fq 'urlCredentialStorage = nil' "$CLIENT" \
    || fail 'credential storage is not disabled'
/usr/bin/grep -Fq 'maximumResponseBytes' "$CLIENT" \
    || fail 'the update response is not size bounded'
/usr/bin/grep -Fq 'timeoutIntervalForResource' "$CLIENT" \
    || fail 'the update request has no resource timeout'

if /usr/bin/grep -Eqi 'Authorization|Bearer|private[_ -]?token|downloadTask|downloadTaskWith' "$CLIENT"; then
    fail 'the manual metadata client contains credentials or artifact-download APIs'
fi

unexpected_network=$(
    /usr/bin/grep -RInE 'URLSession|NWConnection|Network\.framework|CFNetwork|socket\(' \
        "$PROJECT_ROOT/Sources" 2>/dev/null \
        | /usr/bin/grep -v '/Sources/TidyDropApp/UpdateCheckService.swift:' \
        | /usr/bin/grep -v '/Sources/TidyDropUpdateTransport/FixedOriginUpdateTransport.swift:' \
        || true
)
[ -z "$unexpected_network" ] || {
    printf '%s\n' "$unexpected_network" >&2
    fail 'network APIs exist outside the Update Center and gated non-shipping transport'
}

startup_body=$(
    /usr/bin/sed -n '/func applicationDidFinishLaunching/,/^    }/p' "$APP"
)
if printf '%s\n' "$startup_body" | /usr/bin/grep -Eq 'UpdateCheck|UpdateCenter|checkForUpdates'; then
    fail 'application startup invokes the Update Center'
fi

/usr/bin/grep -Fq 'Check for Updates' "$WINDOW" \
    || fail 'the explicit manual check button is missing'
/usr/bin/grep -Fq 'will not download or install' "$WINDOW" \
    || fail 'the non-installing boundary is not visible in the UI'
/usr/bin/grep -Fq 'NSWorkspace.shared.open' "$WINDOW" \
    || fail 'the official release action is missing'
/usr/bin/grep -Fq 'url.host == "github.com"' "$WINDOW" \
    || fail 'browser navigation does not revalidate the official host'

printf '%s\n' 'Update Center policy: PASS'
printf '%s\n' '  manual check only'
printf '%s\n' '  official fixed repository endpoint'
printf '%s\n' '  ephemeral session without credentials or cookies'
printf '%s\n' '  no runtime network in Core, CLI, or LaunchAgent'
printf '%s\n' '  no artifact download or installation path in shipping targets'
