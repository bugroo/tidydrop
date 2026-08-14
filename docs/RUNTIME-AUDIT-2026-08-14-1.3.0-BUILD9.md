# Installed runtime audit — 2026-08-14 — TidyDrop 1.3.0 build 9

This audit covers the immutable public 1.3.0 Community Preview 1 artifact and
the installed runtime after upgrading `/Applications/TidyDrop.app` from build 8
to build 9. No apply or undo test was executed against a personal folder. The
only apply-mode background pass moved zero files.

## Artifact and replacement

- Public tag: `v1.3.0-community.1`.
- DMG SHA-256:
  `e007e2ced311ce6490bff06e57afb94c89523bb4bd637d7a8249bb6b2c9e5e18`.
- The public checksum, GitHub attestation, mounted bundle self-check, Universal 2
  slices and ad hoc signature were verified before replacement.
- Apply was disabled before the old build-8 agent was unregistered.
- The previous complete app was retained under a private temporary recovery
  directory before `/Applications/TidyDrop.app` was replaced.
- The installed bundle reports version 1.3.0, build 9 and Community identity.
- The build-8 service was absent after migration and the versioned build-9
  service was enabled.

An older, inactive user-level `~/Applications/TidyDrop.app` was observed and
left untouched because its provenance and removal were outside this update.

## Background execution

After registration, build 9 was resident but initially had not written a new
scheduled-run record. A process sample placed it inside
`EventDrivenAgent.rebuildWatcher` and `FSEventStreamCreate`. Opening the newly
installed app allowed the normal verification path to complete without a TCC
prompt. The next record reported:

```text
outcome=success
mode=dry-run
moved=0
errors=0
source=~/Downloads
```

After that safe record, the previously configured apply mode was explicitly
restored. A fresh build-9 pass then reported:

```text
outcome=success
mode=apply
moved=0
errors=0
```

The Downloads top-level regular-file and directory counts were unchanged
during this pass. No personal file name was collected for the audit.

## Idle resource sample

A 30-second idle observation of the build-9 agent recorded:

- `0.0%` CPU at both endpoints;
- approximately 12,000 KiB resident memory;
- accumulated CPU time unchanged at `0:00.20`;
- no growth in `steward.log` or `audit.jsonl`;
- no `agent-errors.log`.

This is evidence of normal idle behavior for that interval, not a battery-cycle
or physical-Intel energy certification.

## Finding and required correction

The first-reconciliation dependency on FSEvents setup is a robustness defect,
not evidence of a personal-file move or high energy use. Build 9 works after its
app verification path runs, but a future agent must persist its first safe
reconciliation before potentially blocking watcher setup and reconcile again
after setup to close the event window. Because the Community signature is ad
hoc, that changed agent must use a new versioned label rather than silently
reusing build 9.

The decision and rollout gate are recorded in
[ADR-0014](adr/0014-two-phase-agent-startup-readiness.md).

Follow-up: [ADR-0014](adr/0014-two-phase-agent-startup-readiness.md) implements
the two-phase `agent_ready` protocol and assigns it the new Community build-10
identity. That source correction does not change the installed build-9 state
described by this audit until a separately validated release is installed.

## Current installed state at the end of the audit

- App: TidyDrop 1.3.0 Community, build 9.
- Active folder: `~/Downloads`.
- Agent: build 9 enabled.
- Mode: apply.
- Latest audited pass: success, zero moved, zero errors.
- Personal files moved by the update procedure: zero.

## Remaining limits

- The app is ad hoc signed and not notarized.
- A later binary change can prompt again for Background Items or Files & Folders.
- The agent startup-order finding requires a new versioned Community agent.
- The idle sample does not establish whole-cycle battery impact.
- One active folder is supported at a time.
- The file engine retains the documented residual TOCTOU window immediately
  before rename.
