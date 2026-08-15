# TidyDrop update and recovery roadmap

This roadmap implements [ADR-0011](adr/0011-manual-update-center-and-recovery-boundary.md).
Automatic installation and rollback remain blocked until their acceptance
criteria are proven.

> **Current restart point:** read [HANDOFF.md](HANDOFF.md) before starting new
> work. It separates the public release, the installed runtime audit, and the
> non-shipping update/recovery foundation on `main`.

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

Progress: repository-level immutability is enabled. ADR-0013 adds a separate,
offline, canonical Ed25519 manifest verifier with direct no-follow artifact
hashing and negative tests. It is not linked into the shipping app or agent.
Release asset signing, a pinned production public key, key custody,
rotation/revocation rehearsal and product activation remain mandatory gates.

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

## Gate measurement — 2026-08-15

| Work item | Acceptance status | What remains |
| --- | --- | --- |
| U1 | Complete | None for manual discovery |
| U2 | Complete | Keep static/network gates green |
| U3 | 2 complete, 1 partial, 2 pending | Approve custody; sign release assets; pin the production public key; rehearse rotation and revocation; integrate only after those gates |
| U4 | Technical foundation complete; activation blocked | Fixed-origin transport, private descriptor-bound staging, authenticated length/digest, cancellation/disk-full cleanup and read-only DMG/bundle inspection pass with ephemeral test keys. Product activation still depends on U3 key custody and U7's stable Developer ID requirement |
| U5 | 5 complete, 1 partial | Private state backup, verified current-bundle retention, the separate helper, non-replay dry-run state restoration and the no-privilege boundary pass. Real helper death/relaunch covers all four durable bundle-swap and all five state-restoration boundaries, repeated five times under a hard `/private/tmp` boundary. Stable helper signing, real destination staging, reboot injection and installed-scope orchestration remain |
| U6 | 5 of 6 behaviors demonstrated manually; updater orchestration not built | Build 10 demonstrated old-agent removal, exact-agent registration, stale-agent absence, independent CLI/agent access, ready zero-move dry-run and owner-approved apply restoration. Integration with U5 recovery and in-product post-update confirmation remains unbuilt |
| U7 | Blocked externally and technically | Apple Developer Program identity, Developer ID/notarization, stable signing requirement, physical Intel and full TCC/macOS-upgrade matrix |

ADR-0013 deliberately stops before production key creation and shipping-target
activation. Production signing cannot be completed safely without an
owner-approved custody procedure. Further autonomous work is limited to
foundations that do not require installed-app or production-signing authority.
Installed-app authority remains blocked until
stable signing, the real reboot fault matrix, U6
reconciliation and U7 pass.

The build-10 installed audit is recorded in
[`RUNTIME-AUDIT-2026-08-14-1.3.0-BUILD10.md`](RUNTIME-AUDIT-2026-08-14-1.3.0-BUILD10.md).
It improves U6 evidence but does not claim that a product updater exists.

ADR-0015 starts U4 with an isolated descriptor-bound staging writer and fault
harness. ADR-0017 adds a fixed-origin ephemeral transport and verifies the
authenticated digest before finalization. ADR-0018 revalidates that digest,
mounts a real test DMG read-only, bounds the filesystem tree, verifies exact
bundle identity, all three Universal 2 executables and the complete code
signature. None of these ADRs authorizes product activation or app replacement.

ADR-0019 begins U5 with a private recovery state snapshot. It writes a validated
configuration backup with apply disabled, creates a consistent SQLite online
backup, records digests and schemas in a manifest written last, and cleans exact
workspaces at three injected failure boundaries. It also resolves SQLite paths
from file descriptors so macOS `/tmp` canonicalization cannot defeat the
no-follow policy. ADR-0020 retains and reinspects the current signed Universal 2
bundle through a descriptor-relative copy, records complete bundle/state digests
and publishes an fsync-backed external recovery journal with strict forward
transitions. ADR-0021 adds an independent helper target and uses
descriptor-relative `renameatx_np(RENAME_SWAP)` to install and roll back two
strictly inspected bundle versions. It pins device/inode immediately before the
swap and recovers interruptions on either side of the durable physical mutation.
ADR-0022 launches that helper as a real subprocess, forces `SIGKILL` at each of
the four durable boundaries and proves recovery from a fresh process over five
complete repetitions. ADR-0023 restores only the authenticated, compatible
configuration and optional SQLite state after bundle rollback, normalizes the
SQLite snapshot out of WAL mode, preserves residual live sidecars away from the
restored filename, and verifies that apply remains disabled without invoking
personal-file undo. ADR-0024 kills the helper at each of those five durable
restoration boundaries and proves recovery from a fresh process, five times per
boundary.
The protocol is hard-restricted to private
`/private/tmp/TidyDropIntegration.*` fixtures and the helper is not packaged, so
real reboot recovery and installed-app authority remain unimplemented.
