# ADR-0014: Two-phase agent startup readiness

- Status: Accepted; implemented, published and verified on the installed Mac
- Date: 2026-08-14
- Decision makers: project owner and Codex
- Related: [ADR-0007](0007-event-driven-fsevents-agent.md), [ADR-0012](0012-community-1.3-release-boundary.md), [ADR-0013](0013-offline-ed25519-release-manifest-foundation.md)

## Context

The installed build-9 audit observed the agent resident inside
`FSEventStreamCreate` before it wrote a new startup record. Opening the app later
allowed normal verification to complete. The existing startup order created the
watcher before running startup reconciliation, so a delayed or blocked FSEvents
setup also delayed the only observable safety result.

Writing an ordinary `success` record before watcher creation would be
insufficient: the app could treat that scan as proof that the background watcher
is operational and permit apply while setup is still blocked.

## Decision

Use a two-phase startup record:

1. run a full reconciliation before FSEvents setup and persist
   `agent_ready=false`;
2. create and start the watcher;
3. cancel any provisional follow-up timer from phase 1;
4. reconcile again and persist `agent_ready=true`;
5. mark all later event-driven runs ready.

The second reconciliation closes the file-event window between the first scan
and watcher creation. A phase-1 result remains useful for diagnosis but cannot
authorize automatic organization.

`ScheduledRunRecord.agent_ready` is optional for decode compatibility. The
build-10 Background Verification policy accepts only the explicit value `true`;
both `false` and an older absent value fail closed. CLI status renders explicit
`false` as `watcher_starting`.

A debug-only delay seam pauses watcher setup during integration. The test
requires the phase-1 record to appear before the delay expires, then requires a
different phase-2 record with `agent_ready=true` without opening the app.

Because the agent binary changes under an ad hoc Community signature, it will
ship only under the new label:

```text
io.github.bugroo.tidydrop.agent.community.v10
```

Build 9 remains in the bundle solely as a migration handle. The update must
force dry-run, unregister build 9, register build 10, and prove a fresh
ready=true zero-move run before apply may be restored explicitly.

## Gates

1. Existing JSON records without `agent_ready` still decode but cannot authorize
   Background Verification.
2. A delayed watcher produces `agent_ready=false` before setup completes.
3. The next run is fresh, successful, dry-run, zero-move, zero-error and
   `agent_ready=true` without UI launch.
4. The build-10 bundle includes migration plists 9 through 5 and no duplicate
   active Community service.
5. Event, burst, private request and idle-resource integration remain green.
6. Full debug, release, Swift 6, Universal 2, DMG and CI gates pass.

Local validation on 2026-08-14 passed all six gates: 99 self-tests, 20 repeated
stability-race runs, the delayed-watcher event integration, warnings-as-errors
builds, Universal 2 assembly, Community and development DMG verification, and
the full static audit. The protected public CI gate then reproduced the result
on PR #19. Installed-runtime verification remains a release gate rather than a
prerequisite for accepting the source decision.

Community Preview 2 subsequently published build 10 from protected `main`. The
re-downloaded public DMG passed checksum, GitHub attestation and bundle checks.
The installed agent produced fresh `agent_ready=true` dry-run and apply records,
both with zero moves and zero errors, without requiring the UI to start the
watcher.

## Consequences

- A blocked FSEvents setup becomes observable without being mistaken for a
  working watcher.
- Startup performs at most two bounded scans. The second is normally cheap
  because unchanged dry-run plans and empty audit work are suppressed.
- Records from earlier agents no longer authorize apply after build-10 code is
  installed; a fresh build-10 run is required.
- This is an agent-readiness correction, not an automatic app updater or a TCC
  bypass.
