# ADR-0013: Offline Ed25519 release-manifest foundation

- Status: Accepted and implemented as a non-shipping foundation
- Date: 2026-08-14
- Decision makers: project owner and Codex
- Related: [ADR-0011](0011-manual-update-center-and-recovery-boundary.md), [ADR-0012](0012-community-1.3-release-boundary.md), [Update Center threat model](../tidydrop-update-center-threat-model.md)

## Context

ADR-0011 requires artifacts to be authenticated independently of HTTPS and the
GitHub release API before TidyDrop may download or install an update. GitHub
release immutability and build attestations improve provenance, but neither is
the native application's pinned offline trust root. Attestation verification
also depends on a trusted-root bundle whose roots and revocation state can
change.

The installed 1.3.0 Community build was also audited during a manual upgrade.
The old agent was removed, the new bundle was verified, and build 9 eventually
completed a successful dry-run before apply was restored. However, its first
reconciliation record appeared only after the new app was launched. A process
sample showed the agent waiting inside FSEvents watcher creation. This does not
justify automatic installation; it adds a concrete startup-order gate for the
next versioned agent.

## Decision

Add a separate `TidyDropUpdateSecurity` Swift module with an offline verifier
for a small canonical manifest signed with Ed25519 through CryptoKit.

The canonical version-1 manifest is UTF-8, LF-only, bounded to 4,096 bytes and
contains exactly these ordered fields:

1. release version;
2. channel;
3. bundle identifier;
4. artifact file name;
5. artifact byte length;
6. lowercase SHA-256;
7. minimum macOS version;
8. UTC publication time.

The verifier must:

- reject non-canonical, oversized, malformed, wrong-channel, same-version and
  downgraded manifests;
- reject replay, stale/frozen and implausibly future publication times;
- require the expected bundle ID and exact artifact name;
- open the artifact itself with `O_NOFOLLOW`, require a regular file, bound its
  size, hash it by streaming, and compare `fstat` identity, size and nanosecond
  modification time before and after hashing;
- compare the measured length and digest to the authenticated manifest;
- reject unsupported macOS versions;
- remain offline and independent of the file-organization agent.

The module is linked only into the independent self-test executable for now.
It is not imported by the app, CLI, Core or LaunchAgent, and therefore cannot
download, accept or install an update.

No production signing key or pinned production public key is created by this
ADR. Release signing, custody, recovery access, rotation, revocation and a
rehearsed ceremony require a separate owner-approved operational decision.
Ephemeral keys generated inside tests are never persisted.

GitHub artifact attestations remain a second provenance signal. They do not
replace the future pinned Ed25519 public key.

## Startup-order gate discovered during the installed upgrade

The next changed Community agent must receive a new versioned label. Its startup
sequence must write a bounded initial reconciliation result before a potentially
blocking FSEvents setup, then create the watcher and reconcile once more to
cover the setup window. Integration must prove the first record without opening
the UI and must keep apply disabled until that record is fresh and successful.

This correction is intentionally not hidden inside the build-9 identity: ad hoc
binary changes require a new Community agent label to avoid stale
`SMAppService` launch constraints.

## Gates

The foundation is complete only when:

1. debug and release builds pass with warnings as errors;
2. canonical encode/decode and a valid signature pass;
3. wrong key, malformed signature, non-canonical encoding, downgrade, replay,
   stale/future time, bundle/name mismatch, altered size/digest, excessive size,
   unsupported OS, and symlink inputs fail closed;
4. a static gate proves no networking, product-side private-key code or shipping
   target activation entered the module;
5. the complete pre-existing validation matrix remains green.

## Consequences

- U3 now has a reusable, tested offline verification primitive.
- U3 is not complete: future release assets are not yet signed with this format,
  the app has no pinned production public key, and rotation/revocation has not
  been rehearsed.
- U4–U6 remain prohibited. No downloader, extractor, installer or automatic
  rollback is introduced.
- The verifier reduces file-race exposure during hashing but cannot eliminate a
  later TOCTOU window between completed verification and a future installer;
  staging and installation must retain descriptor-bound or equivalent controls.

## References

- [Apple CryptoKit: Curve25519.Signing](https://developer.apple.com/documentation/cryptokit/curve25519/signing)
- [Apple: Storing CryptoKit keys in the Keychain](https://developer.apple.com/documentation/cryptokit/storing-cryptokit-keys-in-the-keychain)
- [GitHub: Verify attestations offline](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/verify-attestations-offline)
- [Apple: SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
