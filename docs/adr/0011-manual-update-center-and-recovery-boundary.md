# ADR-0011: Manual Update Center and recovery boundary

- Status: Accepted; phase 1 implemented and validated
- Date: 2026-08-14
- Decision makers: project owner and Codex
- Related: [ADR-0002](0002-distribution-updates-and-tcc-continuity.md), [ADR-0004](0004-community-preview-without-developer-id.md), [ADR-0010](0010-community-1.2-release-boundary.md)
- Security analysis: [Update Center threat model](../tidydrop-update-center-threat-model.md)

## Context

TidyDrop Community Preview is distributed as an ad hoc signed GitHub prerelease.
It does not yet have the stable Developer ID identity required for a silent,
notarized update path or dependable TCC continuity across binary replacement.
The application also promises that normal file organization is local-only and
that background operation does not create network traffic.

Users nevertheless need a clear way to learn that a newer build exists and a
documented recovery path if a future update fails. An update mechanism is a
supply-chain boundary: release discovery, artifact selection, authentication,
installation, agent migration, TCC verification, and rollback must not be
collapsed into a single unaudited button.

GitHub's `releases/latest` endpoint excludes prereleases. The Community Preview
channel therefore cannot use that endpoint and must explicitly inspect the
repository release list and select only strict Community version tags.

## Decision

### Phase 1: manual, private release discovery

TidyDrop will add a native AppKit Update Center with these properties:

- no check at launch, on a timer, or from the background agent;
- network access occurs only after the user presses **Check for Updates**;
- the app queries one fixed HTTPS API endpoint owned by this project:
  `https://api.github.com/repos/bugroo/tidydrop/releases`;
- the request uses an ephemeral URL session with no cookies, credential store,
  persistent cache, authorization header, PAT, device identifier, file names,
  folder paths, or system profile;
- response size, status, and parsing are bounded and fail closed;
- Community builds accept only strict `vX.Y.Z-community.N` prereleases;
- future stable builds accept only strict `vX.Y.Z` non-prereleases;
- drafts, malformed tags, wrong channels, the current version, and downgrades
  are ignored;
- release links are constructed from the fixed official repository origin, not
  trusted from response-provided URLs;
- the Update Center may open the official release page, but it never downloads,
  mounts, installs, replaces, relaunches, or rolls back an application;
- TidyDropCore, the CLI, and the LaunchAgent remain network-free.

The UI must state that Community builds are ad hoc signed and not notarized.
It must not describe a release as verified merely because it was returned by
the GitHub API.

### Phase 2: authenticated artifacts and staged installation

Automatic download or installation remains prohibited until all of these gates
are implemented and verified:

1. immutable future GitHub releases;
2. an independently signed release manifest with version, channel, bundle ID,
   artifact name, length, SHA-256, minimum macOS version, and publication time;
3. a pinned public verification key in the application and documented offline
   key rotation/revocation;
4. anti-downgrade, freeze, mix-and-match, and replay protection;
5. download to a private staging directory with bounded size and no symlinks;
6. signature, manifest, architecture, bundle identity, and code-signing checks
   before replacement;
7. atomic replacement that preserves the previous complete bundle;
8. private, versioned backups of configuration and the SQLite schema;
9. an out-of-process recovery component able to restore the prior bundle when
   the new application cannot launch;
10. re-registration and health verification of the bundled `SMAppService`
    agent, with `apply_enabled=false` throughout the update;
11. a fresh app and LaunchAgent access check for the exact active folder;
12. explicit user confirmation before any return to apply mode.

### Phase 3: Developer ID distribution

Automatic update will be reconsidered only after Developer ID signing,
Hardened Runtime, notarization, stapling, stable designated requirements, and
real-device TCC continuity tests are available. A maintained updater framework
may be evaluated then, but adopting one requires a separate dependency and XPC
review; it is not implicitly approved by this ADR.

### Rollback semantics

Rollback means restoring the last known-good **application bundle and compatible
state**, not using TidyDrop's file-operation `undo`. These are separate safety
domains.

A rollback must never:

- reverse organized personal files;
- overwrite current configuration or journals without a compatible backup;
- restore apply mode automatically;
- depend on the potentially broken newly installed process;
- cross stable and Community channels;
- restore an artifact whose digest and signature were not recorded before the
  update.

Until phase 2 is complete, recovery is manual: quit TidyDrop, reinstall a named
prior GitHub release, re-register the included agent, and validate a fresh
dry-run. The project must not label that procedure “automatic rollback.”

## Privacy and energy contract

- Manual checks create no periodic wakeups.
- The event-driven agent remains entirely offline.
- Update metadata is held in memory for the current Update Center session and is
  not added to the activity database or file-operation audit log.
- The request discloses only the ordinary network metadata inherent in an HTTPS
  connection plus a minimal TidyDrop user-agent string.
- Release notes are opened in the user's browser; no WebKit view or remote HTML
  is embedded in TidyDrop.

## Release gates

Phase 1 is complete only when:

1. strict version and channel selection tests pass;
2. same-version and downgrade releases are rejected;
3. no automatic invocation exists in application startup or the agent;
4. static audit limits runtime networking to the Update Center source file;
5. the app builds with warnings as errors for supported architectures;
6. the complete existing validation matrix remains green;
7. README and security documentation accurately narrow the former “no network”
   claim to background organization and explain the manual check;
8. a GitHub release is not mutated in place to deliver the feature.

## Repository control applied

On 2026-08-14 the repository API reported immutable releases disabled. After
confirming that the Community workflow already creates a draft, attaches and
revalidates every asset, and only then publishes it, release immutability was
enabled for `bugroo/tidydrop`. A second API query returned `enabled: true`.

GitHub applies this protection only to future releases. The existing
`v1.2.0-community.2` release remains mutable and is not treated as an immutable
or independently signed update source.

## Phase 1 verification evidence

The 2026-08-14 macOS validation run completed with:

- 92/92 native self-tests passing, including six Update Center regressions;
- stability race suite 20/20 passing;
- debug, release, and Swift 6 builds with warnings as errors;
- Update Center policy audit passing with one allowlisted manual client and no
  networking in Core, CLI, or LaunchAgent;
- idle agent sample at `0.0%` CPU with no increase in accumulated CPU time;
- Universal 2 `arm64`/`x86_64` bundle and DMG assembly, ad hoc code-signing
  verification, checksum verification, and release-pipeline validation passing;
- dry-run demo with `moved=0`, `errors=0`, and zero personal files touched;
- a final internal manifest covering 130 regular project files.

The generated evidence is stored under `docs/evidence/`, including
`update-center.txt`, `self-tests.txt`, `event-agent.txt`,
`release-pipeline.txt`, and `validation-result.txt`.

## Consequences

### Benefits

- Users get a discoverable update button without surrendering installation
  control.
- There are no new background wakeups or agent network permissions.
- Strict channel parsing prevents Community builds from silently switching to a
  stable or malformed feed entry.
- The project records the engineering gates required for a real rollback before
  implementation begins.

### Costs and limitations

- Users still download and install Community updates manually.
- GitHub learns the source IP and normal HTTPS request metadata when the user
  explicitly checks.
- The GitHub API response is transport-protected but is not an independently
  signed artifact manifest.
- An ad hoc update may trigger a new macOS background-item or Files & Folders
  approval because its code identity changes.

## Rejected alternatives

- **Check automatically at launch:** adds network activity and launch latency
  without a user action.
- **Use `/releases/latest`:** it omits Community prereleases.
- **Trust asset URLs or checksums from arbitrary release text:** same-origin
  metadata is not an independent signature.
- **Download and replace the app in phase 1:** unsafe without authenticated
  metadata, staging, recovery, agent migration, and TCC gates.
- **Use file-operation undo as app rollback:** it protects different assets and
  would risk personal files.
- **Adopt an updater dependency immediately:** premature expansion of supply
  chain and XPC surface before Developer ID distribution exists.

## References

- [GitHub REST API: releases](https://docs.github.com/en/rest/releases/releases)
- [GitHub: Preventing changes to releases](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/establish-provenance-and-integrity/prevent-release-changes)
- [GitHub: Immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
- [Apple: Updating Mac software](https://developer.apple.com/documentation/security/updating-mac-software)
- [Apple: Securing file operations](https://developer.apple.com/documentation/security/secure-coding-guide)
- [Apple: SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
