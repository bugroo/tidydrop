# TidyDrop update and recovery roadmap

This roadmap implements [ADR-0011](adr/0011-manual-update-center-and-recovery-boundary.md).
Automatic installation and rollback remain blocked until their acceptance
criteria are proven.

## Phase 1 — Manual Update Center

### U1 — Discover newer official releases (5 points)

As a TidyDrop user, I want to check for a newer release from the app so that I
can learn about updates without background tracking.

Acceptance criteria:

- the check starts only from an explicit AppKit action;
- Community and stable channels use separate strict tag policies;
- drafts, malformed tags, same versions, and downgrades are ignored;
- the session is ephemeral and sends no credentials, file metadata, or device
  identifier;
- errors are bounded, actionable, and do not affect the agent;
- no artifact is downloaded or installed.

Dependencies: none.

### U2 — Make phase-1 boundaries auditable (3 points)

As a maintainer, I want tests and static controls around updater networking so
that later changes cannot silently add polling or background downloads.

Acceptance criteria:

- TidyDropCore, CLI, and agent contain no networking APIs;
- runtime networking is allowlisted to the Update Center client only;
- source checks reject automatic startup invocation and authorization headers;
- all existing validation gates remain green;
- privacy, energy, and ad hoc TCC limitations are documented.

Dependencies: U1.

## Phase 2 — Authenticated staged updates

### U3 — Publish immutable signed release metadata (5 points)

As a user, I want each artifact authenticated independently of transport so that
a modified feed or asset is rejected.

Acceptance criteria:

- future releases are immutable;
- an offline-protected Ed25519 key signs a canonical manifest;
- the app pins the public key and verifies signature, version, channel, bundle
  identity, artifact name, size, digest, and minimum OS;
- negative tests cover downgrade, replay, freeze, mix-and-match, wrong key,
  altered size, and altered digest;
- key rotation and revocation are documented and rehearsed.

Dependencies: release-operation design and key-custody approval.

Progress: repository-level immutability is enabled for future releases. The
independently signed manifest and key lifecycle remain unimplemented gates.

### U4 — Download and stage without installing (5 points)

As a user, I want a verified update prepared safely so that I can review it
before replacement.

Acceptance criteria:

- bounded download into a private app-owned no-follow staging directory;
- no cookies, credentials, redirects to unapproved origins, or executable launch;
- artifact digest and signature verified before extraction;
- extracted bundle is regular, bounded, Universal 2 where required, and has the
  expected identifiers and signing requirement;
- cancellation and disk-full conditions leave the current app untouched.

Dependencies: U3.

### U5 — Install with an external recovery path (8 points)

As a user, I want a failed update to restore the last known-good app so that a
bad build does not strand TidyDrop.

Acceptance criteria:

- configuration and schema-compatible state are backed up privately;
- the current verified bundle is retained before atomic replacement;
- recovery is controlled by a minimal process outside the new bundle;
- every interruption point is fault-injected, including process kill and reboot;
- rollback never replays file-operation undo and always leaves apply disabled;
- no `sudo`, Full Disk Access, or TCC database modification is introduced.

Dependencies: U4.

### U6 — Reconcile agent and TCC after update or rollback (8 points)

As a user, I want the exact new or restored agent proven safe before automation
resumes so that stale registrations or permissions cannot move files incorrectly.

Acceptance criteria:

- the old bundled agent is unregistered before replacement;
- the exact installed agent is registered with `SMAppService`;
- duplicate and stale agents are rejected;
- app and LaunchAgent access are checked independently for the exact active
  folder;
- a fresh dry-run reports `moved=0` and `errors=0`;
- apply returns only after explicit confirmation.

Dependencies: U5.

## Phase 3 — Production distribution

### U7 — Developer ID and notarized update channel (8 points)

As a nontechnical user, I want a normally trusted macOS update experience so
that I do not need ad hoc Gatekeeper workarounds.

Acceptance criteria:

- Developer ID identity, Hardened Runtime, notarization, and stapling pass;
- app, agent, recovery component, and update artifacts share compatible signing
  requirements;
- update and rollback pass on Apple Silicon and physical Intel hardware;
- TCC continuity is tested on Downloads, Documents, Desktop, removable, and
  network volumes, including after a supported macOS upgrade;
- a maintained updater framework is adopted only after a separate supply-chain,
  XPC, energy, and rollback assessment.

Dependencies: Apple Developer Program identity, signing-key custody, U6.
