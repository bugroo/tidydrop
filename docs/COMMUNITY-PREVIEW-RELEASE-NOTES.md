# TidyDrop 1.1.0 Community Preview

TidyDrop keeps one folder organized locally. It does not upload file names,
metadata, content, or usage information.

## Important security notice

This Community Preview is **not signed with Apple Developer ID and is not
notarized by Apple**. macOS cannot verify the developer identity. Install it only
from this official `bugroo/tidydrop` GitHub Release.

Do not disable Gatekeeper, remove quarantine attributes, grant Full Disk Access,
or run a remote installation script.

## Install

1. Download `TidyDrop-1.1.0-community-preview-macos-universal.dmg` below.
2. Open the DMG and drag `TidyDrop.app` to Applications.
3. Try to open TidyDrop once. macOS is expected to block the first launch.
4. Open **System Settings → Privacy & Security** and select **Open Anyway**.
5. Open TidyDrop and allow its background item and selected folder if macOS asks.
6. Register the background agent and run the safe preview.
7. Enable automatic organization only after the preview reports zero errors.

The first run and every update start with automatic moving disabled.

## Verify the download

Place the DMG and `.sha256` file in the same folder, then run:

```sh
shasum -a 256 -c TidyDrop-1.1.0-community-preview-macos-universal.sha256
```

Contributors with GitHub CLI can also verify that GitHub built the DMG from this
repository:

```sh
gh attestation verify \
  TidyDrop-1.1.0-community-preview-macos-universal.dmg \
  --repo bugroo/tidydrop
```

Build provenance confirms origin; it is not Apple notarization and does not by
itself prove that software is safe.

## Included

- Native AppKit onboarding app.
- Foundation-only background agent registered with `SMAppService`.
- Universal 2 binaries for Apple Silicon and Intel.
- Dry-run, conservative apply and undo, collision protection, fresh POSIX
  metadata snapshots, bounded logs, and local-only operation.
- One active folder at a time, defaulting to Downloads.

## Known limitations

- macOS can request Open Anyway or Files & Folders approval again after updates.
- One folder is active at a time.
- Intel hardware still requires an installation test on a physical Intel Mac.
- A small residual TOCTOU interval exists between the last metadata check and an
  atomic rename.
