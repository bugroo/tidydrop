# ADR-0021: External recovery helper and destination-volume atomic swap

- Status: Accepted; non-shipping, temporary-scope foundation implemented
- Date: 2026-08-15
- Decision makers: project owner and Codex
- Related: [ADR-0020](0020-retained-current-bundle-and-recovery-journal.md)

## Context

ADR-0020 makes the old app and recovery intent durable, but it deliberately has
no process capable of replacing either bundle. A conventional sequence that
renames the old app away and then renames the new app into place creates an
interval with no app at the canonical path. It also makes crash reconciliation
depend on guesses about which rename completed.

Apple's installed `renameatx_np(2)` contract exposes `RENAME_SWAP`, which swaps
two entries atomically when the destination filesystem supports it. The same
API accepts directory descriptors and no-follow/beneath resolution flags.

## Decision

Add a minimal independent Swift executable, `tidydrop-recovery-helper`, and a
descriptor-relative replacement protocol to the non-shipping recovery module.

For this foundation only, replacement authority is hard-limited to a canonical,
owner-private `TidyDropIntegration.*` hierarchy under `/private/tmp`. The helper
is compiled as a separate SwiftPM product but is not copied into `TidyDrop.app`,
the DMG, the CLI, or the LaunchAgent. It cannot address `/Applications`.

The protocol:

- opens a mode-private destination parent and candidate container with
  `O_DIRECTORY | O_NOFOLLOW`;
- requires both app entries on the same device and owned by the effective user;
- strictly inspects the current and candidate signed Universal 2 bundles for
  the versions recorded in the authenticated recovery journal;
- records device and inode for both inspected entries and rechecks them
  immediately before mutation;
- writes `replacement_started` before the swap;
- atomically exchanges `TidyDrop.app` and the candidate `TidyDrop.app` using
  `renameatx_np` with `RENAME_SWAP` and `RENAME_NOFOLLOW_ANY`;
- fsyncs both containing directories;
- reinspects the post-swap pair before writing `new_bundle_installed`;
- applies the same ordered protocol in reverse for rollback;
- reconciles both interruption windows: journal durable before swap, and swap
  durable before the following journal state.

`ENOTSUP` or `EINVAL` from the atomic primitive fails closed. There is no
fallback to a non-atomic two-rename sequence.

## Verification

Four isolated in-process regressions prove:

- successful atomic install and rollback preserve the expected signed versions;
- interruption immediately after each physical swap is reconciled without a
  second swap;
- interruption after each intent journal but before its swap resumes forward;
- broad scope and a symlink candidate are rejected without advancing the
  journal.

All physical replacement and rollback operations occur below `/private/tmp`.
At adoption, the complete independent suite contained 127 tests; the current
project total is tracked in `docs/VALIDATION.md`.

[ADR-0022](0022-recovery-helper-process-kill-harness.md) additionally kills the
real helper subprocess at all four durable boundaries and reconciles each
transaction from a fresh helper process. The dedicated gate repeats that matrix
five times. A real reboot matrix remains outstanding.

## Consequences

### Benefits

- The canonical app name is never absent during a supported atomic swap.
- Recovery can distinguish pre-swap and post-swap states from two independently
  signed bundle versions instead of trusting path existence alone.
- The helper is outside both exchanged app bundles and can outlive either one.
- Identity pinning narrows the TOCTOU window between inspection and mutation.

### Remaining gates

- copy, sign, and verify a Universal 2 helper with the stable production
  Developer ID requirement;
- bind that exact helper requirement and the release public key into immutable
  recovery metadata instead of the ephemeral test identity;
- stage the candidate container on the real destination volume without granting
  installed-app authority prematurely;
- restore a schema-compatible state snapshot and force the live configuration
  to dry-run;
- run a real reboot fault matrix at every journal boundary;
- integrate exact agent removal/registration, separate TCC checks, zero-move
  dry-run validation, and explicit apply confirmation.

### Residual risks

- `fsync` reduces but cannot eliminate filesystem or hardware failure.
- Filesystems without atomic swap support are rejected.
- The macOS 15 SDK does not expose `RENAME_RESOLVE_BENEATH`. This protocol does
  not need it because both rename operands are fixed single-component names
  relative to already-open no-follow directory descriptors; accepting caller
  paths as operands would invalidate this decision.
- The temporary helper foundation is intentionally not a product updater and
  cannot update an installed TidyDrop app.
- A same-account attacker remains outside TidyDrop's threat model, although
  descriptor and device/inode checks reject accidental path substitution.

## Primary platform evidence

- macOS `renameatx_np(2)` manual, verified from the active Command Line Tools.
- macOS SDK `usr/include/sys/stdio.h`, which declares `RENAME_SWAP`,
  `RENAME_NOFOLLOW_ANY`, and `renameatx_np` in supported deployment SDKs.
- [Apple Secure Coding Guide: Race Conditions and Secure File Operations](https://developer.apple.com/library/archive/documentation/Security/Conceptual/SecureCodingGuide/Articles/RaceConditions.html)

## Subsequent decisions

[ADR-0022](0022-recovery-helper-process-kill-harness.md) adds real subprocess
death at the four durable bundle boundaries. [ADR-0023](0023-schema-bound-dry-run-state-restoration.md)
adds the compatible dry-run state restoration that follows a successful bundle
rollback. Installed-app authority and real reboot testing remain gated.
