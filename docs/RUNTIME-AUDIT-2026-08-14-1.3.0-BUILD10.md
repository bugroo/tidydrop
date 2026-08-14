# Installed runtime audit — 2026-08-14 — TidyDrop 1.3.0 build 10

This audit covers the immutable public Community Preview 2 artifact and the
installed runtime after replacing build 9. No manual apply or undo command was
executed against the personal active folder. The only apply-mode verification
was a normal background-agent startup pass after a zero-candidate preview.

## Public artifact

- Tag: `v1.3.0-community.2`.
- Tagged commit: `0b617d88e4411866a36fe2a728952e6aca1c807e`.
- Publication workflow: `31840825411`, successful.
- DMG SHA-256:
  `fea68f2f017fb75e52ee67f3673c712bdd6d68c9f52b433b7a622c2d90d710e3`.
- The public checksum, GitHub build attestation, mounted bundle, ad hoc
  signature, bundle identifiers, three executables and both Universal 2 slices
  were verified after re-downloading the published assets.

## Safe replacement and recovery

- The installed build 9 was healthy and configured for apply before the update;
  its last pass reported success, zero moves and zero errors.
- Apply was disabled before unregistering build 9.
- The build-10 bundle was staged and independently verified before replacement.
- The complete previous bundle remains in a private temporary recovery
  directory; no previous app was deleted.
- The installed app now reports version 1.3.0, build 10 and the Community
  identity.
- Build 9 is absent from Service Management and only build 10 is running.

## Two-phase startup verification

Without opening the graphical app, the new agent wrote a fresh result with:

```text
outcome=success
mode=dry-run
agent_ready=true
moved=0
errors=0
source=~/Downloads
```

This proves that the installed agent reached the post-FSEvents phase rather
than merely completing the diagnostic pre-watcher scan. A separate installed
CLI preview then scanned 12 first-level entries, planned zero moves, moved zero
files and reported zero errors. The top-level personal-file and directory
counts were unchanged.

After that gate, apply was restored through the explicit owner-approved CLI
action. A forced build-10 background restart produced a different fresh result:

```text
outcome=success
mode=apply
agent_ready=true
moved=0
errors=0
source=~/Downloads
```

The top-level counts remained unchanged. No personal file name was collected
for this audit.

## Idle resource sample

A 30-second idle observation after the apply verification recorded:

- `0.0%` CPU at both endpoints;
- accumulated CPU time unchanged at `0:00.10`;
- resident memory declining from 12,832 KiB to 9,504 KiB;
- no new scheduled-run record;
- zero bytes of combined log growth.

This sample supports normal idle behavior on this Apple Silicon Mac. It is not
a whole-battery-cycle measurement or a physical-Intel energy certification.

## Installed state at the end of the audit

- App: TidyDrop 1.3.0 Community, build 10.
- Active folder: `~/Downloads`.
- Agent: Community build 10 enabled and ready.
- Mode: apply.
- Latest audited pass: success, zero moved, zero errors.
- Personal files moved by the update procedure: zero.
- Full Disk Access, `sudo`, TCC database changes and background network access:
  not used.

## Remaining limits

- The Community app is ad hoc signed and not notarized by Apple.
- A later binary or macOS change can request Files & Folders or Background Items
  consent again; TidyDrop must recheck the real app and agent access.
- One active folder is supported at a time.
- Physical Intel and full macOS-upgrade/TCC matrices remain untested.
- The file engine retains the documented residual TOCTOU interval immediately
  before atomic rename.
- Automatic update download, installation and rollback remain deliberately
  disabled.
