# ADR-0008: Agent-owned SQLite activity index

- Status: Accepted for 1.2 implementation
- Date: 2026-08-14
- Decision makers: project owner and Codex
- Related: [ADR-0006](0006-appkit-workbench-information-architecture.md), [ADR-0007](0007-event-driven-fsevents-agent.md)

## Context

The workbench needs a bounded, queryable view of background-agent runs. The
transaction manifests and scheduled-status JSON already protect file-operation
correctness, but scanning those files is not an appropriate long-term activity
index and must not turn the UI into another writer of operational state.

## Decision

TidyDrop stores a derived activity index at
`Application Support/TidyDrop/state/activity.sqlite3` using the SQLite library
provided by macOS.

- The scheduled agent execution path is the only production writer.
- The AppKit process opens the database with `SQLITE_OPEN_READONLY` and verifies
  the connection is actually read-only.
- Transaction manifests remain authoritative for apply, reconciliation, and
  undo. `last-scheduled-run.json` remains the current health record. Deleting or
  rebuilding the SQLite index must not authorize, repeat, or invalidate a file
  move.
- Schema changes use `PRAGMA user_version` and explicit migrations. A database
  from a newer schema is rejected rather than guessed.
- Run IDs are primary keys and inserts are idempotent upserts. All values use
  prepared statements and bound parameters.
- Retention keeps at most 1,000 run rows. The database is rejected before open
  if it is a symlink, not a regular file, or larger than 64 MiB.

## Storage and connection security

The state directory is private and local to the user. Database opens use
`SQLITE_OPEN_NOFOLLOW`, private cache, serialized connection mode, a bounded
busy timeout, and extended result codes. The database and any WAL/SHM sidecars
are forced to mode `0600`; the parent remains `0700`.

Every connection disables trusted schema. The writer requests WAL and verifies
that the pragma returned `wal`; failure is closed and reported in the bounded
agent error log. A passive checkpoint follows each small run write and
autocheckpointing is limited to 128 pages.

WAL files are part of database state and are never removed directly. The
activity database belongs in local Application Support, not on the selected
source volume or a network filesystem. The selected folder may still be local,
external, or network-backed because its location is independent from the
activity database.

## Failure behavior

Writing the current scheduled JSON record succeeds before indexing is
attempted. If SQLite is unavailable or corrupt, the agent records a bounded
diagnostic and continues to preserve file-operation truth in JSON/manifests.
The workbench degrades only the background-run summary; activity, rules,
transactions, and undo remain available.

## Consequences

The UI can query recent background runs without parsing an unbounded log, and a
reader never competes with the agent for write ownership. SQLite adds one Apple
system-library dependency and up to two temporary sidecars. WAL improves
reader/writer coexistence but uses fewer durability barriers under
`synchronous=NORMAL`; this is acceptable only because the index is derived and
non-authoritative.

## Verification gates

1. A scheduled dry-run creates one indexed row without moving files.
2. Schema migration, newest-first reads, idempotent upsert, and private
   permissions pass in `/private/tmp`.
3. A missing database is not created by the reader.
4. Symlink database and WAL sidecar paths are rejected without changing their
   targets.
5. Opening the writer proves WAL was activated; failure closes the handle.
6. Static audit proves only `ScheduledExecution` calls the writer and that the
   required open/security flags remain present.
7. Event-agent integration observes a regular private database while the
   installed application and personal folders remain untouched.

## References

- [Opening a new SQLite database connection](https://www.sqlite.org/c3ref/open.html)
- [Write-Ahead Logging](https://www.sqlite.org/wal.html)
- [PRAGMA trusted_schema](https://www.sqlite.org/pragma.html#pragma_trusted_schema)
