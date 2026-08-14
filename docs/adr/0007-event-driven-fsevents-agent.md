# ADR-0007: Event-driven FSEvents agent

- Status: Accepted and implemented in TidyDrop 1.2.0
- Date: 2026-08-14
- Decision makers: project owner and Codex
- Related: [ADR-0001](0001-native-macos-application-architecture.md), [ADR-0006](0006-appkit-workbench-information-architecture.md)

## Context

The 1.1 agent runs one bounded pass every 300 seconds. Empty scheduled passes are
already silent and inexpensive, but the timer still wakes the Mac even when the
folder has not changed and can delay organization for several minutes.

Apple documents FSEvents as a lightweight notification mechanism for directory
hierarchies. It can coalesce events, report dropped events, and notify at
directory granularity. It therefore cannot authorize a move or replace a full
reconciliation.

## Decision

The bundled agent becomes a long-lived, Foundation/CoreServices-only process.
It watches the active source with FSEvents and remains blocked on a dispatch
queue when idle.

### Event handling

- File events are requested, but every signal is treated only as a reason to
  run the existing engine.
- Repeated events are debounced into one run.
- Only source-root or direct-child changes are relevant because TidyDrop does
  not recurse into subdirectories.
- Configuration changes rebuild the stream and trigger reconciliation.
- A private, atomically replaced request file lets the app request a safe
  verification from an already-running agent. The request must use a known
  version, a UUID, the canonical active source, and a recent timestamp; it is
  consumed once after validation. It is a local transition mechanism until the
  signed XPC gate is complete and carries no apply command.
- Root changes, mount changes, event-ID wrap, and user/kernel dropped events
  trigger full reconciliation.
- The agent watches `/Volumes` only when the selected source resides there, so a
  remount can recover an unavailable source without creating the path.

### Stability scheduling

The engine remains authoritative. If a run reports deferred candidates, the
agent creates one `DispatchSourceTimer` for the next stability observation. A
new source event replaces that timer. When no candidate is pending, the timer
is cancelled and no periodic timer remains.

The timer uses leeway and utility/background priority. There is never one timer
per file.

### Recovery and correctness

The agent performs one reconciliation after startup and when stream flags say
events may have been lost. Every actual move continues to require fresh POSIX
snapshots, journal-before-rename, exclusive collision handling, and the final
pre-move identity check. FSEvents never carries enough authority to bypass
those gates.

If the source is unavailable, the agent records `source_unavailable`, does not
create the path, and waits for a relevant root/mount/config signal. A bounded
retry is permitted only after lock contention or an event-triggered transient
error; it is not a permanent polling loop.

### LaunchAgent

Bundled `SMAppService` agents use `RunAtLoad` and remain alive themselves.
`StartInterval` is removed from the bundled agent. The legacy source installer
continues to use its periodic one-shot agent until its separate migration is
implemented and verified.

## Consequences

Idle source folders no longer cause five-minute process launches or scans, and
new files are noticed promptly. The resident process consumes a small fixed
memory footprint, so release gates must compare RSS, CPU time, wakeups, and I/O
against the one-shot baseline. FSEvents-specific behavior remains macOS-only;
the shared engine and self-tests stay portable.

Current isolated Apple Silicon integration samples after source, burst, and
app-request events held CPU time unchanged, sampled `0.0%` CPU, and measured
11,824–13,072 KiB RSS. These are bounded observations rather than an energy
guarantee; wakeups and I/O still require Instruments during the release
candidate gate, and physical Intel measurement remains external.

## Verification gates

1. A temporary source event triggers a dry-run and produces a new scheduled
   record with zero moves.
2. A burst of writes is coalesced and a changing file is never moved.
3. A deferred file receives a later stability observation from one timer.
4. No timer exists after the queue becomes idle.
5. Dropped/root-change flags force reconciliation.
6. A configuration/source change rebuilds the watcher and remains dry-run.
7. Source unavailable does not create the path and recovers after remount or
   configuration change.
8. Shutdown and launchd restart do not leave concurrent agents.
9. Idle CPU, wakeups, RSS, and I/O are measured on the current Apple Silicon
   Mac; physical Intel measurement remains an external gate.

## References

- [File System Events](https://developer.apple.com/documentation/coreservices/file_system_events)
- [Using the File System Events API](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html)
- [FSEventStreamSetDispatchQueue](https://developer.apple.com/documentation/coreservices/fseventstreamsetdispatchqueue)
