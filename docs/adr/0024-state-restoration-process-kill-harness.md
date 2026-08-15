# ADR-0024: State-restoration helper process-kill and relaunch harness

- Status: Accepted and implemented as a non-shipping fault-injection gate
- Date: 2026-08-15
- Decision makers: project owner and Codex
- Related: [ADR-0022](0022-recovery-helper-process-kill-harness.md), [ADR-0023](0023-schema-bound-dry-run-state-restoration.md)

## Context

ADR-0023 proved five interruption boundaries with caught Swift errors. As with
the earlier bundle-swap protocol, an in-process error does not prove that a
fresh process can reconcile only the synchronized journal and filesystem state
after abrupt termination.

## Decision

Extend the non-shipping helper with a `restore-state` command and five test-only
checkpoints:

1. candidates and residual-sidecar isolation synchronized, before restoration
   intent is published;
2. `state_restoration_started` synchronized, before the configuration swap;
3. configuration swap synchronized, before its journal transition;
4. `configuration_restored` synchronized, before the activity-state swap;
5. activity-state swap synchronized, before `state_restored` is published.

At each checkpoint the helper creates an exclusive mode `0600` marker through
the already validated owner-private workspace descriptor, synchronizes marker
and directory, and stops with `SIGSTOP`. The parent validates the exact marker,
sends `SIGKILL` to that child, waits for signal termination and launches a new
helper with the same authenticated transaction.

The fresh helper must reach `state_restored`, report apply disabled, restore
only the pre-update activity row, and leave both a personal-file sentinel and a
file-operation transaction sentinel byte-identical. The dedicated gate repeats
all five boundaries five times, producing twenty-five forced process deaths.

The command and checkpoints remain in the non-shipping helper/module. Static
gates continue to prohibit recovery imports in the app, CLI and agent and to
prohibit the helper in `TidyDrop.app` or either DMG.

## Consequences

### Benefits

- All safely automatable U5 mutation boundaries now have real process-death and
  fresh-process recovery coverage.
- The test proves that application state rollback cannot replay personal-file
  undo after an abrupt helper death.
- CI repeats the same 25-kill matrix as complete local validation.

### Remaining gate

- A real reboot, abrupt host shutdown and power/filesystem recovery matrix is
  still required. `SIGKILL` does not simulate loss of kernel or storage caches.

### Residual risks

- Test-only checkpoint hooks must not enter a production-signed helper build.
- `fsync` narrows but cannot eliminate storage-device failure.
- Installed-app authority, stable signing and U6 agent/TCC orchestration remain
  separately gated.
