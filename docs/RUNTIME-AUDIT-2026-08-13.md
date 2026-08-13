# Installed runtime audit — 13 August 2026

## Scope

Read-only inspection of the locally installed TidyDrop 1.0.2 after overnight
operation. No personal file names or contents were copied into this report. The
only manual execution used for measurement was an explicit dry-run.

## Operational result

```text
LaunchAgent runs observed:        162
LaunchAgent last exit code:       0
Last scheduled outcome:           success
Last scheduled mode:              apply
Last scheduled errors:            0
Files moved since activation:     13
Completed transactions:           1
Completed move records:           13
Failed or ambiguous moves:        0
Moves still eligible for undo:    13
```

All 13 completed records matched the expected physical state: the original path
was absent and the recorded destination existed. No source had unexpectedly
reappeared and no destination was missing.

The active folder contained ten top-level directories and one hidden regular
file. The hidden file was correctly ignored. The category folders contained 13
organized files in total. This explains why later scheduled passes reported 11
scanned and 11 skipped entries with no additional moves.

## Integrity and permissions

- The installed app and LaunchAgent plist passed their native validation.
- The app had a valid ad hoc signature and no Team ID, as expected for the
  current local-only installation.
- Configuration and plist files were owned by the current user and mode `0600`.
- App, state, and log directories were owned by the current user and mode `0700`.
- No symbolic links were present inside the app, state, or log directories.
- The audit JSONL and transaction manifests parsed successfully.
- No agent error log existed because the agent had not recorded an error.
- Logs remained below their configured 5 MiB bound; total log storage was 328
  KiB and state storage was 32 KiB.

## Resource measurement

One explicit dry-run over the current folder produced:

```text
Elapsed time:                     0.02 s
User CPU:                         0.00 s
System CPU:                       0.00 s
Maximum resident set size:        15,056,896 bytes
Swaps:                            0
Block input operations:           0
Block output operations:          0
Files moved:                      0
Errors:                           0
Resident TidyDrop process after:  none
TidyDrop power assertions:        none
```

The Mac was connected to AC power at 80% battery, so this session cannot measure
an overnight battery-discharge percentage. It does show that TidyDrop was not a
resident process, held no power assertion, and returned to idle after a very
short pass. The current five-minute interval can still cause up to 12 launches
per hour. Apple recommends avoiding periodic polling when event notifications
are available because timer-driven wakeups have an energy cost. Replacing polling
with filesystem events remains the correct direction for the future native app.
([Apple: Minimize Timer Usage](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html),
[Apple: Energy Efficiency Best Practices](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/BestPractices.html))

## Finding TD-RUN-001 — unbalanced run boundaries

**Severity:** Low. No file operation or recovery guarantee was affected.

The historical audit contained 32 run IDs:

```text
Complete run_started/run_finished pairs: 8
run_finished without run_started:        24
run_started without run_finished:        0
```

Scheduled no-op suppression intentionally omitted `run_started` before knowing
whether a pass would produce an event. When the pass later logged a deferred,
planned, or moved item, it wrote `run_finished` without first opening the run.
This made otherwise valid audit records harder to interpret as complete units.

### Correction

The engine now opens the run lazily before its first substantive event. A truly
empty scheduled pass remains silent. Any eventful pass is recorded in this order:

```text
run_started → event(s) → run_finished
```

Regression `testScheduledEventfulRunWritesBalancedAuditBoundaries` verifies the
ordering and shared run ID. The existing silent no-op regression remains in
place. Historical records are preserved unchanged; the fix applies to future
runs after the updated binary is installed.

## Conclusion

The installed version organized the folder successfully and showed no data-loss,
transaction, permission, agent, sustained-CPU, or storage-growth failure. The
only reproduced defect concerned audit-boundary completeness and has been fixed
in the source with a regression test. The installed binary was not replaced
during this audit because replacing an ad hoc signed app may trigger a new macOS
Files & Folders decision, while the current file-moving behavior is healthy.
