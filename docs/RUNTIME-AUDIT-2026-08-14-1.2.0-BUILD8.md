# Installed runtime audit — 2026-08-14 — TidyDrop 1.2.0 build 8

This audit covers the official TidyDrop 1.2.0 Community Preview 2 artifact and
the installed macOS runtime after upgrading from Community build 7. No apply or
undo command was run against a personal folder, and no personal file names were
collected for this report.

## Official artifact

- Release: [`v1.2.0-community.2`](https://github.com/bugroo/tidydrop/releases/tag/v1.2.0-community.2)
- Source commit: `fe8ba0a0445eb8c79affa7251563e1a5eae9cfac`
- Release workflow: [Publish Community Preview run 31800151882](https://github.com/bugroo/tidydrop/actions/runs/31800151882)
- DMG SHA-256: `661e7fe8c59d28311c651d0cbd7d0c994d0cddd6e2e99b61403e6cc42b5bddcc`
- The public checksum matched the downloaded DMG.
- GitHub artifact attestation verification returned exit status 0.
- The downloaded DMG passed the repository's bundle and release verification:
  Community channel, ad hoc signature, Hardened Runtime, three Universal 2
  executables, regular bundle entries, valid plists, and the build-8 agent.

## Installed state

- `/Applications/TidyDrop.app` reports version 1.2.0 and build 8.
- App, CLI, and agent contain native `arm64` and `x86_64` slices.
- `codesign --verify --deep --strict` passed. The Community Preview remains ad
  hoc signed and therefore has no Apple Team ID.
- The build-8 agent label is loaded and running. Community labels for builds 7,
  6, and 5, the future stable label, and the legacy label are not loaded.
- The active folder is `~/Downloads`, its manual and LaunchAgent access checks
  both report success, and the configured mode is `dry-run`.
- The fresh background result at `2026-08-14T12:30:15Z` was `success`,
  `dry-run`, `moved=0`, and `errors=0`.
- The AppKit workbench independently displayed **Enabled and verified**,
  **Preview only**, and a successful background run with zero moves.
- The upgrade explicitly wrote `apply_enabled=false` before and after replacing
  the bundle. It did not invoke real apply or undo.

## Runtime and energy observation

The Mac was connected to AC power with the battery at 80%, so this observation
cannot attribute a battery-percentage change to TidyDrop. Over a settled
30-second sample:

- the resident agent reported 0.0% CPU in both samples;
- accumulated CPU time changed from 0.12 to 0.13 seconds;
- resident memory changed from 7,920 to 10,240 KiB;
- `steward.log` remained at 130,496 bytes;
- `audit.jsonl` remained at 154,046 bytes;
- the SQLite file remained at 16,384 bytes and six rows;
- no new agent run was recorded;
- no TidyDrop power assertion existed; and
- no agent error log had been created because no agent error had been recorded.

These measurements show no abnormal CPU, write, or wakeup pattern during the
observed idle period. They are a bounded runtime sample, not a long-duration
battery benchmark. `powermetrics` was not used because the audit deliberately
does not request `sudo`.

## Data integrity and permissions

- SQLite `PRAGMA quick_check` returned `ok`; all six indexed runs had zero
  errors.
- Application Support, state, and log directories were `0700`.
- The configuration and SQLite database were `0600`.
- No symlink existed inside the installed app, Application Support, or log
  trees.
- Four existing transaction manifests remained present after the upgrade.
- Log sizes and database row count were unchanged during the idle sample.

## Energy correction included in build 8

Build 7 requested `kFSEventStreamCreateFlagNoDefer`, which Apple documents for
interactive clients. TidyDrop is a background batch consumer, so build 8 uses
the default deferred delivery with a two-second latency. This lets macOS
coalesce short bursts before waking the agent while preserving startup
reconciliation, source filtering, debounce, fresh POSIX stability snapshots,
and the final pre-move check.

The policy is covered by a self-test and a static gate that rejects a future
reintroduction of `NoDefer`. The complete project validation passed with 86/86
self-tests, 20/20 stability-race repetitions, event-agent integration,
Universal 2 builds, DMG revalidation, manifest verification, and zero personal
files moved.

## Remaining limits

- The Community Preview is ad hoc signed and not notarized. A binary update may
  cause macOS to ask for the background item or Files & Folders decision again.
- The 30-second idle sample does not replace a battery-cycle study on battery
  power or measurement on a physical Intel Mac.
- One active folder is supported at a time.
- An unavailable cloud, network, or external folder fails closed and is retried
  after a later filesystem event or relaunch; it is not recreated.
- The final fresh `lstat(2)` cannot eliminate the residual TOCTOU window before
  an atomic rename without cooperation from the process writing the file.

## References

- [Apple: `kFSEventStreamCreateFlagNoDefer`](https://developer.apple.com/documentation/coreservices/kfseventstreamcreateflagnodefer)
- [Apple: FSEvent stream latency](https://developer.apple.com/documentation/coreservices/1443980-fseventstreamcreate)
- [Apple: Minimize Timer Usage](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html)
