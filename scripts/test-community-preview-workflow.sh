#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
WORKFLOW="$PROJECT_ROOT/.github/workflows/community-preview.yml"

[ -f "$WORKFLOW" ] && [ ! -L "$WORKFLOW" ] || {
    printf '%s\n' 'ERROR: falta el workflow de Community Preview.' >&2
    exit 1
}

require_literal() {
    literal=$1
    /usr/bin/grep -Fq -- "$literal" "$WORKFLOW" || {
        printf 'ERROR: falta el gate comunitario: %s\n' "$literal" >&2
        exit 1
    }
}

require_literal 'contents: write'
require_literal 'id-token: write'
require_literal 'attestations: write'
require_literal 'actions/attest@508db95dd578ae2727ebd6217d5ba78e4fbda05d'
require_literal 'package-release.sh "$app" "$artifacts" community'
require_literal '"$release_tag"'
require_literal 'verify-dmg.sh" "$downloaded_dmg" community'
require_literal 'gh attestation verify "$downloaded_dmg"'
require_literal '--prerelease'
require_literal '--latest=false'

if /usr/bin/grep -Eq 'APPLE_(TEAM|DEVELOPER|NOTARY)|Developer ID Application' "$WORKFLOW"; then
    printf '%s\n' 'ERROR: el canal comunitario no debe consumir identidad o secretos Apple.' >&2
    exit 1
fi
if /usr/bin/grep -q 'pull_request_target' "$WORKFLOW"; then
    printf '%s\n' 'ERROR: el workflow comunitario no puede usar pull_request_target.' >&2
    exit 1
fi

printf '%s\n' 'Community Preview workflow: PASS (prerelease + checksum + provenance + revalidation)'
