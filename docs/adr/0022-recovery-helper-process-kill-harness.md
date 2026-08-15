# ADR-0022: Recovery-helper subprocess kill and relaunch harness

- Status: Accepted and implemented as a non-shipping fault-injection gate
- Date: 2026-08-15
- Decision makers: project owner and Codex
- Related: [ADR-0021](0021-external-recovery-helper-and-atomic-swap.md)

## Context

ADR-0021 proved the replacement state machine with injected Swift errors. An
error thrown inside one process does not prove that the durable journal and
atomic swap remain sufficient after the operating system destroys that process.
The U5 recovery gate therefore still required a real helper subprocess to die
at each durable install and rollback boundary and a fresh helper process to
reconcile the transaction.

This is still a temporary-scope foundation. It must not gain authority over an
installed application or become part of a release artifact.

## Decision

Add four test-only checkpoints to the non-shipping replacement protocol:

1. `replacement_started`, after the intent journal is synchronized and before
   the install swap;
2. `install_swap_synchronized`, after the install swap and both directory
   `fsync` calls, before `new_bundle_installed` is recorded;
3. `rollback_started`, after the rollback intent is synchronized and before the
   rollback swap;
4. `rollback_swap_synchronized`, after the rollback swap and both directory
   `fsync` calls, before `rolled_back` is recorded.

The independent helper accepts a narrowly named test environment variable only
for `install` and `rollback`. At the requested checkpoint it creates one fixed,
exclusive `0600` marker through an owner-private workspace directory descriptor,
synchronizes the marker and directory, and stops itself with `SIGSTOP`. The test
parent observes and validates that marker, sends `SIGKILL` to that exact child,
waits for termination, and starts a new helper with `recover`.

The harness then verifies:

- the recovered terminal journal state;
- the expected signed current and target bundle versions on both sides of the
  atomic swap;
- no skipped or failed test;
- no operation outside `/private/tmp/TidyDropIntegration.*`.

The process test is conditionally registered only when the gate supplies an
owned, executable, regular file named `tidydrop-recovery-helper`. Ordinary
`tidydrop-self-test` runs remain independent of that binary. The dedicated gate
repeats all four boundaries five times, producing twenty forced process deaths.

Static checks prohibit the test environment hook in the app, CLI, agent and
core, and continue to prohibit copying the helper into `TidyDrop.app` or a DMG.

## Consequences

### Benefits

- Recovery is now exercised by a fresh process rather than only by a caught
  in-process error.
- Both sides of every durable mutation boundary are covered symmetrically.
- The marker itself is durable evidence that the child reached the intended
  boundary before it was killed.
- CI and complete local validation run the same repeated process harness.

### Remaining gates

- A real reboot or abrupt host shutdown matrix is still required. `SIGKILL`
  proves process death, not kernel, filesystem, power-loss or hardware failure.
- The test checkpoint hook must not ship in a future production recovery helper;
  production fault injection requires a separately controlled test build.
- Stable Developer ID requirements, real destination-volume staging, dry-run
  state restoration and U6 agent/TCC reconciliation remain blocked separately.

### Residual risks

- `fsync` narrows but does not eliminate filesystem or hardware failure risk.
- A same-account attacker remains outside the current threat model.
- The helper remains intentionally incapable of updating the installed app.

## Subsequent decision

[ADR-0023](0023-schema-bound-dry-run-state-restoration.md) implements the
previously blocked dry-run state-restoration foundation. [ADR-0024](0024-state-restoration-process-kill-harness.md)
extends its five checkpoints to real process death and fresh-process recovery.
Only the real reboot/host-shutdown matrix remains outstanding.
