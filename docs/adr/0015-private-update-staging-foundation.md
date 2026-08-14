# ADR-0015: Private descriptor-bound update staging foundation

- Status: Accepted and implemented as a non-shipping foundation
- Date: 2026-08-14
- Decision makers: project owner and Codex
- Related: [ADR-0011](0011-manual-update-center-and-recovery-boundary.md), [ADR-0013](0013-offline-ed25519-release-manifest-foundation.md), [Update Center threat model](../tidydrop-update-center-threat-model.md)

## Context

U4 requires a downloaded update to enter a private bounded staging area without
being executable, mounted, extracted or installed first. The current Update
Center only discovers releases; it does not download assets. ADR-0013 provides
offline manifest and artifact authentication but previously assumed that an
artifact already existed at a safe local path.

A future network transport cannot safely write directly to Downloads, a shared
temporary file, the application bundle, or a path selected only by an untrusted
response. Cancellation, disk exhaustion, symlink replacement and a late name
collision must fail without altering the installed app or personal files.

Apple's secure-file guidance recommends private directories, descriptor-based
operations, `O_NOFOLLOW`, `fstat`, and exclusive creation instead of a separate
path existence check. Apple also documents ephemeral URL sessions as avoiding
persistent caches, cookies and credential storage. The latter remains a future
transport requirement; this ADR introduces no network client.

## Decision

Add `PrivateUpdateStagingWriter` to the already gated
`TidyDropUpdateSecurity` module. It is a streaming sink, not a downloader.

Creation must:

1. accept only an `AuthenticatedReleaseManifest` emitted after Ed25519 policy
   verification, so signed metadata bounds the artifact name and expected
   length;
2. open an existing absolute parent with `O_DIRECTORY`, `O_NOFOLLOW` and
   `O_CLOEXEC`;
3. require a current-user-owned parent with no group or world write bit and no
   symlink component in its canonical path;
4. create a random private workspace using `mkdirat(..., 0700)`;
5. open the partial artifact relative to that workspace with
   `O_CREAT|O_EXCL|O_NOFOLLOW` and mode `0600`;
6. preflight available bytes with `fstatfs` while still treating later
   `ENOSPC`/`EDQUOT` as normal bounded failures.

Streaming must never buffer the complete artifact. Every append is bounded by
both the authenticated expected length and an independent maximum. The writer
handles interrupted POSIX writes, rejects zero-progress writes, and exposes an
explicit cancellation path.

Finalization must:

- require the exact authenticated byte length;
- synchronize the descriptor;
- recheck type, ownership, mode, link count, device, inode and size with
  `fstat`;
- rename the partial file inside the private workspace with
  `renameatx_np(..., RENAME_EXCL)`;
- verify the final directory entry with `fstatat(..., AT_SYMLINK_NOFOLLOW)` and
  a final `lstat` identity check;
- return the staged path only after all checks pass.

Cancellation and failed writes remove only the exact partial file and empty
workspace through their already-open directory descriptors. Cleanup is
non-recursive, app-owned and marked for static audit. An unexpected entry makes
directory removal fail safely rather than broadening deletion.

The default fault path uses real POSIX calls. A bounded disk-full injection is
retained in this non-shipping module so CI can prove mid-stream `ENOSPC`
behavior without filling a runner disk.

## Activation boundary

The app, CLI, Core and LaunchAgent must not import `TidyDropUpdateSecurity`.
This foundation contains no `URLSession`, browser, `Process`, mount, extraction,
Service Management, `/Applications` replacement or relaunch path.

U4 remains incomplete. A future ADR must still define and test:

- a fixed-origin ephemeral downloader feeding this writer;
- redirect, content-length, timeout, cancellation and bandwidth bounds;
- authenticated integration with a pinned production key;
- safe DMG mounting or another extraction format;
- extracted bundle limits, path traversal rejection, architecture, identifier
  and code-signing validation;
- cancellation and disk-full tests across the real transport/extraction flow.

No production downloader or updater activation is authorized by this ADR.

## Gates

1. Swift 6 warnings-as-errors build passes.
2. A multi-chunk artifact finalizes with private permissions and retains
   device/inode identity.
3. The staged artifact passes the existing signed-manifest verifier.
4. Symlink and group/world-writable parent roots fail closed.
5. Oversized, incomplete, cancelled and injected disk-full writes clean only
   their private partial workspace.
6. A late final-name collision is never overwritten.
7. Static audit proves there is no network, mounting, install or shipping-target
   activation.
8. The full existing validation matrix remains green.

## Consequences

- U4 gains a reusable, bounded local sink and deterministic failure harness.
- The installed app and Community DMG remain unchanged because no shipping
  target links the module.
- An authenticated artifact can later be streamed and verified without first
  trusting a shared path.
- Successful staging deliberately leaves its private workspace for the future
  verification/extraction state machine; retention and recovery require U5.
- Descriptor anchoring substantially reduces path races but cannot defend
  against a process already running with the same user authority and arbitrary
  code execution.

## References

- [Apple Secure Coding Guide: Race Conditions and Secure File Operations](https://developer.apple.com/library/archive/documentation/Security/Conceptual/SecureCodingGuide/Articles/RaceConditions.html)
- [Apple Foundation: ephemeral URLSessionConfiguration](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/ephemeral)
- [Apple Security: SecStaticCodeCheckValidity](https://developer.apple.com/documentation/security/secstaticcodecheckvalidity%28_%3A_%3A_%3A%29)
