# ADR-0020: Retain the verified current bundle before replacement

- Status: Accepted; non-shipping foundation implemented
- Date: 2026-08-15
- Decision makers: project owner and Codex
- Related: [ADR-0018](0018-safe-authenticated-dmg-bundle-inspection.md), [ADR-0019](0019-private-recovery-state-snapshot.md)

## Context

The state snapshot from ADR-0019 cannot recover a missing or broken application.
Before any future replacement, TidyDrop must retain the complete current bundle
and publish enough durable state for a process outside the new bundle to decide
whether to continue or roll back.

Using a path-only recursive copy would reopen symlink, hardlink, replacement and
time-of-check/time-of-use problems. A journal written only after replacement
would also leave an unrecoverable interruption window.

## Decision

Extend the non-shipping recovery module with two foundations:

1. a descriptor-bound current-bundle retention builder; and
2. an fsync-backed external recovery journal state machine.

The retention builder:

- applies the existing bounded identity, version, Universal 2 and strict code
  signature inspection to the current bundle before copying;
- opens directories and files relative to descriptors with `O_NOFOLLOW` and
  `AT_SYMLINK_NOFOLLOW`;
- rejects symlinks, hardlinks, special files, cross-device traversal,
  group/world-writable entries and special permission bits;
- copies each regular file exclusively with `fcopyfile(COPYFILE_ALL)`, preserving
  code-signing material and executable permissions;
- checks source metadata around every file copy and reinspects the source bundle
  after the complete copy;
- reinspects the retained bundle with the same policy;
- records a deterministic SHA-256 digest of the complete retained tree plus the
  digest of the ADR-0019 state manifest;
- refuses to overwrite or delete a previously published retained transaction;
- removes only artifacts created by the failed current attempt.

The journal starts in `prepared` with `apply_enabled=false`. Its allowed forward
transitions are explicit. Every update is written as a mode `0600` `.next` file,
fsynced, then renamed over the current journal and followed by a directory
`fsync`. If interruption occurs after the `.next` file is durable, the loader
validates transaction identity, immutable fields, sequence and transition before
publishing it. It also rehashes the state manifest and retained bundle before
returning any journal state.

This foundation does not replace an app, stop or start an agent, register a
service, change TCC, or execute rollback. It remains linked only to the
independent self-test target.

## Journal states

```text
prepared
  -> replacement_started
       -> new_bundle_installed
            -> validation_succeeded -> committed
            -> rollback_started -> rolled_back -> committed
       -> rollback_started -> rolled_back -> committed
```

No reverse, repeated, skipped, or post-commit transition is accepted.

## Verification

Five isolated regressions prove that:

- a signed Universal 2 bundle is retained, reinspected and journaled privately;
- three injected copy/publication failures remove only newly-created retained
  artifacts while preserving the state snapshot;
- a symlink source and a tampered retained tree are rejected;
- a synchronized `.next` journal survives an injected interruption and is
  recovered exactly once;
- wrong-version and symlink bundles are rejected by the reusable existing-bundle
  inspector.

The complete independent suite now contains 123 tests. All fixture bundles,
copy operations and journal transitions occur under `/private/tmp`.

## Consequences

### Benefits

- A future external helper can rely on a retained, signed, tree-digested current
  app and a schema-compatible dry-run state snapshot before replacement begins.
- A crash between journal write and publication is recoverable without guessing.
- Retrying preparation cannot erase the already-published recovery source.
- The same verification logic protects staged, installed and retained bundles.

### Remaining work

- build and sign the minimal recovery executable outside both old and new apps;
- stage the new bundle on the destination volume and define the exact atomic
  replacement primitive;
- implement bundle restoration and state compatibility selection;
- fault-inject process kill and reboot at every replacement/recovery boundary;
- integrate exact-agent removal, registration, TCC checks and fresh zero-move
  dry-run confirmation;
- complete production-key custody, Developer ID, notarization and physical Intel
  validation before activation.

### Residual risks

- The current user can modify owner-writable recovery data; stable signed helper
  identity and strict requirement checks remain necessary.
- `fsync` narrows but cannot eliminate hardware and filesystem failure modes.
- This journal records recovery intent but has no authority to replace or launch
  software in the implemented foundation.

## References

- [Apple: Race Conditions and Secure File Operations](https://developer.apple.com/library/archive/documentation/Security/Conceptual/SecureCodingGuide/Articles/RaceConditions.html)
- [Apple: FileManager replacement](https://developer.apple.com/documentation/foundation/filemanager/replaceitemat%28_%3Awithitemat%3Abackupitemname%3Aoptions%3A%29)
- [Apple: `copyfile(3)`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/copyfile.3.html)
