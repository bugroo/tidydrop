# ADR-0019: Private recovery state snapshot before app replacement

- Status: Accepted; non-shipping foundation implemented
- Date: 2026-08-15
- Decision makers: project owner and Codex
- Related: [ADR-0011](0011-manual-update-center-and-recovery-boundary.md), [ADR-0018](0018-safe-authenticated-dmg-bundle-inspection.md)

## Context

An authenticated update is still unsafe if replacing the application can strand
the user with incompatible state or re-enable file moves after a rollback. The
recovery data must exist before replacement, be usable by a process outside the
new bundle, and remain separate from personal-file transaction `undo`.

TidyDrop currently has configuration version 1 and an agent activity SQLite
schema version 1. The file-operation journals remain in the existing state
directory and must never be replayed as part of application rollback.

macOS can report an existing path beneath `/private/tmp` using the `/tmp`
spelling. SQLite's `SQLITE_OPEN_NOFOLLOW` correctly rejects the latter because
`/tmp` is a symlink. Recovery tests exposed this edge case even though the
underlying regular file was safe.

## Decision

Add a separate, non-shipping `TidyDropUpdateRecovery` module that prepares a
private recovery state snapshot from an authenticated target manifest.

The snapshot builder:

- accepts only a pre-existing, owner-controlled parent already at mode `0700`
  and never creates or changes that parent;
- creates a unique mode `0700` workspace beneath it;
- reads and validates the current configuration through `ConfigurationIO`;
- writes a mode `0600` configuration backup with `apply_enabled=false`;
- leaves the live configuration unchanged at this foundation stage;
- uses SQLite's online backup API for a transactionally consistent copy of the
  optional activity database, including WAL state;
- accepts only the supported SQLite schema and runs `PRAGMA integrity_check` on
  the copy;
- records SHA-256 digests, schemas, source and target versions, bundle identity,
  and the forced dry-run state in a bounded JSON manifest written last;
- synchronizes files and directories before publishing success;
- removes only its exact, newly-created workspace after an injected failure;
- never copies, replaces, launches, registers, or removes an application bundle.

SQLite paths are anchored through an open descriptor. On macOS, `F_GETPATH`
provides the physical path. The code then confirms device and inode before
SQLite opens the file with `SQLITE_OPEN_NOFOLLOW`. The same physical-parent
resolution is applied to the private backup destination. This preserves the
no-follow policy without rejecting legitimate `/private/tmp` test state.

The module is not imported by the app, CLI, agent, or Core runtime entrypoints.
Only the independent self-test executable links it.

## Recovery transaction ordering

The future external recovery transaction must use this order:

1. stop and verify the old agent;
2. atomically set the live configuration to dry-run and verify it;
3. prepare and verify this state snapshot;
4. retain and authenticate the complete current app bundle;
5. stage the new bundle on the destination volume;
6. publish an interruption-safe recovery journal;
7. perform the atomic bundle replacement;
8. validate the exact new app and agent;
9. recover the prior bundle and compatible state if health verification fails;
10. keep apply disabled until the user explicitly confirms it again.

ADR-0019 implements step 3 only. It does not authorize steps 1, 2, or 4–10.

## Verification

Four new isolated regressions prove that:

- configuration and SQLite state are backed up privately and the backup is
  forced to dry-run while the live test configuration is left unchanged;
- failures after configuration backup, after SQLite backup, and before manifest
  publication leave no recovery workspace behind;
- a symlink recovery parent and a symlink activity database are rejected.
- an explicitly `/tmp`-spelled source and destination reopen successfully only
  after descriptor-derived physical-path and identity validation.

All test data is created below `/private/tmp`. No installed application,
LaunchAgent, personal folder, or real configuration participates.

## Consequences

### Benefits

- Future rollback has a schema-checked state source that cannot restore apply.
- Live SQLite WAL data is copied consistently rather than copied as unrelated
  files.
- The `/tmp` physical-path hardening also improves normal SQLite reopening.
- The boundary remains testable without Xcode, network access, privileges, or a
  Developer ID identity.

### Remaining work

- retain and authenticate the current complete app bundle;
- build and sign the minimal external recovery executable;
- define an fsync-backed recovery journal and atomic replacement protocol;
- fault-inject every boundary, including killed processes and reboot recovery;
- prove bundle restoration, exact-agent registration, TCC access, and a fresh
  zero-move dry-run;
- complete Developer ID, Hardened Runtime, notarization, and physical Intel
  validation before activation.

### Residual risks

- A malicious process running as the same user can target owner-writable update
  state; stable code identity and external recovery validation remain required.
- A state snapshot alone cannot recover a missing or broken app bundle.
- APFS and `FileManager.replaceItem` reduce replacement risk but do not replace
  an independently journaled recovery protocol and fault testing.

## References

- [Apple: FileManager replacement](https://developer.apple.com/documentation/foundation/filemanager/replaceitemat%28_%3Awithitemat%3Abackupitemname%3Aoptions%3A%29)
- [Apple: Race Conditions and Secure File Operations](https://developer.apple.com/library/archive/documentation/Security/Conceptual/SecureCodingGuide/Articles/RaceConditions.html)
- [SQLite: Online Backup API](https://www.sqlite.org/backup.html)
