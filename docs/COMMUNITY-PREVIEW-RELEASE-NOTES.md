# TidyDrop 1.3.0 Community Preview

TidyDrop keeps one folder organized locally. It does not upload file names,
metadata, content, or usage information. Its optional manual Update Center sends
only a bounded, credential-free release-metadata request to the official GitHub
repository after the user presses the button.

## Important security notice

This Community Preview is **not signed with Apple Developer ID and is not
notarized by Apple**. macOS cannot verify the developer identity. Install it only
from this official `bugroo/tidydrop` GitHub Release.

Do not disable Gatekeeper, remove quarantine attributes, grant Full Disk Access,
or run a remote installation script.

## Install

1. Download `TidyDrop-1.3.0-community-preview-macos-universal.dmg` below.
2. Open the DMG and drag `TidyDrop.app` to Applications.
3. Try to open TidyDrop once. macOS is expected to block the first launch.
4. Open **System Settings → Privacy & Security** and select **Open Anyway**.
5. Open TidyDrop and allow its background item and selected folder if macOS asks.
6. Enable background organization and let TidyDrop verify a safe preview run.
7. Enable automatic organization only after the preview reports zero errors.

The first run and every update start with automatic moving disabled.

## Verify the download

Place the DMG and `.sha256` file in the same folder, then run:

```sh
shasum -a 256 -c TidyDrop-1.3.0-community-preview-macos-universal.sha256
```

Contributors with GitHub CLI can also verify that GitHub built the DMG from this
repository:

```sh
gh attestation verify \
  TidyDrop-1.3.0-community-preview-macos-universal.dmg \
  --repo bugroo/tidydrop
```

Build provenance confirms origin; it is not Apple notarization and does not by
itself prove that software is safe.

## Included

- A native manual Update Center that checks only the official Community channel
  after an explicit button press. It never downloads, installs, or rolls back
  the application.
- Strict release parsing that rejects drafts, malformed tags, wrong channels,
  the current version, and downgrades; release navigation is fixed to the
  official repository origin.
- A native three-pane AppKit workbench for the active folder, activity, ordered
  rules, transaction history, inspection, and conservative undo.
- A Foundation/CoreServices FSEvents agent that sleeps while idle, reconciles at
  startup, and uses one bounded timer only for files still changing.
- Background-oriented FSEvents delivery that coalesces bursts instead of using
  the interactive `NoDefer` flag, reducing avoidable wakeups.
- A bounded local SQLite activity index written only by the agent and consumed
  read-only by the workbench; JSON journals remain authoritative for recovery
  and undo.
- A Community build-9 migration path from builds 8, 7, 6, and 5 for macOS ad hoc
  launch constraints.
- Signed-XPC, security-scoped bookmark, and minimal Sandbox prototypes verified
  in tests but deliberately excluded from this ad hoc release until a stable
  Developer ID identity is available.
- Automatic relaunch verification bound to the exact active folder and a recent
  zero-move preview run.
- Protection against selecting `/Applications`, TidyDrop's bundles, symlink
  roots, the whole home directory, or other unsafe roots.
- Foundation-only background work registered with `SMAppService`; AppKit remains
  in the user-facing process.
- Universal 2 binaries for Apple Silicon and Intel.
- Dry-run, conservative apply and undo, collision protection, fresh POSIX
  metadata snapshots, bounded logs, and local-only file organization.
- One active folder at a time, defaulting to Downloads.

## Known limitations

- macOS can request Open Anyway or Files & Folders approval again after updates.
- One folder is active at a time.
- Intel hardware still requires an installation test on a physical Intel Mac.
- A small residual TOCTOU interval exists between the last metadata check and an
  atomic rename.
- Update discovery is manual. Automatic installation and application rollback
  remain blocked until signed metadata, private staging, external recovery,
  agent migration, and TCC gates are implemented and verified.
