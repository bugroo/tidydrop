# ADR-0023: Schema-bound dry-run state restoration after app rollback

- Status: Accepted and implemented as a temporary-scope non-shipping foundation
- Date: 2026-08-15
- Decision makers: project owner and Codex
- Related: [ADR-0019](0019-private-recovery-state-snapshot.md), [ADR-0021](0021-external-recovery-helper-and-atomic-swap.md), [ADR-0022](0022-recovery-helper-process-kill-harness.md)

## Context

Restoring the previous application bundle is insufficient if the failed target
has changed configuration or derived state. Recovery must restore only state
that is compatible with the retained app, must leave automation disabled, and
must never confuse application rollback with personal-file `undo`.

The activity index uses SQLite WAL mode during normal agent operation. SQLite
documents that WAL mode persists in the database header, that a read-only WAL
database may need `-wal` and `-shm`, and that a read-only final connection may
leave shared-memory state behind. A recovery snapshot therefore cannot safely
authenticate only the main SQLite file unless the copy is first normalized out
of WAL mode.

## Decision

Add a forward-only restoration protocol to the non-shipping recovery module.
It accepts only an authenticated ADR-0019 snapshot and an ADR-0020 journal
already in `rolled_back` or a later restoration state. It then:

1. verifies the journal-to-manifest digest, transaction, bundle identity and
   source/target version binding;
2. rejects unsupported configuration or activity-database schemas before any
   live mutation;
3. requires the snapshot configuration to contain `apply_enabled=false`;
4. opens only fixed filenames through owner-private directory descriptors below
   `/private/tmp/TidyDropIntegration.*`;
5. checkpoints the live activity database with a zero busy timeout, converts it
   to rollback-journal `DELETE` mode and fails closed if another writer holds it;
6. validates and atomically preserves residual SQLite sidecars under
   transaction-bound names so they cannot attach to the restored database;
7. writes bounded `0600` candidates, synchronizes file and directory state,
   and uses descriptor-relative `renameatx_np` with no-follow and exclusive or
   swap semantics;
8. records `state_restoration_started`, `configuration_restored` and
   `state_restored` as durable forward transitions;
9. reconciles the live/candidate SHA-256 pair after an interruption instead of
   repeating or guessing the physical mutation;
10. reopens the restored SQLite database read-only, checks schema and
    `PRAGMA integrity_check`, and revalidates the exact dry-run configuration.

SQLite online backups use connection-local exclusive locking so their WAL index
stays in memory, then normalize to `journal_mode=DELETE` before closing. The
accepted artifact must have no `-wal`, `-shm` or rollback-journal file.

The protocol never imports or invokes the organization engine, transaction
store, file-operation undo, Service Management, network transport, TCC tools or
installed-app paths. If no activity backup existed, the derived live database
is intentionally left unchanged while configuration still returns to dry-run.

## Verification

Five isolated regressions prove that:

- configuration and schema-compatible activity state return to the snapshot;
- personal-file and file-operation transaction sentinels remain byte-identical;
- all five injected restoration boundaries recover idempotently;
- incompatible schemas fail before live mutation;
- a symlink destination and an active SQLite writer fail closed;
- an absent activity backup preserves the newer derived database;
- the restored and displaced databases remain readable and the final
  configuration has apply disabled.

The complete self-test suite and a dedicated static gate run in CI. All
physical mutation fixtures are below `/private/tmp`; the installed application,
agent, active folder and personal files are outside the protocol's authority.

## Consequences

### Benefits

- U5 now has a concrete non-replay state rollback path rather than only a
  snapshot.
- Authentication covers the state actually restored, without unauthenticated
  WAL content.
- The sequence is retryable after errors on either side of each atomic swap.
- A failed app update cannot restore an apply-enabled configuration.

### Remaining gates

- Kill-and-relaunch testing must be extended from bundle swaps to the state
  restoration checkpoints.
- A real reboot or abrupt-host-shutdown matrix is still required.
- Production use still requires stable helper signing, destination-volume
  staging, installed-app authority and U6 agent/TCC reconciliation.

### Residual risks

- A same-account attacker remains outside the current threat model.
- `fsync` and atomic rename cannot eliminate storage-device or kernel faults.
- There is a residual race between quiescing SQLite and replacement; a
  production coordinator must stop and verify the exact agent first.

## References

- [SQLite: Write-Ahead Logging](https://www.sqlite.org/wal.html)
- [SQLite: WAL-mode file format](https://www.sqlite.org/walformat.html)
- [SQLite: PRAGMA journal_mode](https://www.sqlite.org/pragma.html#pragma_journal_mode)
