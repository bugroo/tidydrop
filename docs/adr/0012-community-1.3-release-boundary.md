# ADR-0012: TidyDrop 1.3 Community release boundary

- Status: Accepted; release candidate validated, publication pending
- Date: 2026-08-14
- Decision makers: project owner and Codex
- Related: [ADR-0010](0010-community-1.2-release-boundary.md), [ADR-0011](0011-manual-update-center-and-recovery-boundary.md)

## Context

ADR-0011 phase 1 is implemented and validated on macOS: TidyDrop can manually
discover a newer strict release without downloading or installing code. Shipping
that feature changes the ad hoc signed application and bundled agent binaries.

An ad hoc signature has no stable Team ID. Replacing the binary while reusing the
Community build-8 `SMAppService` label can leave macOS enforcing the old launch
constraint. TidyDrop has already observed this failure mode during earlier
Community upgrades. The release must therefore use a new versioned Community
agent and preserve an explicit migration path.

## Decision

Publish the completed manual Update Center as **TidyDrop 1.3.0 Community
Preview**, tag `v1.3.0-community.1`, with Community agent build 9:

```text
io.github.bugroo.tidydrop.agent.community.v9
```

The application bundle includes the build-8, build-7, build-6, and build-5
plists only as migration handles. Before build 9 is registered, TidyDrop
unregisters any enabled or approval-pending prior Community service through
`SMAppService`.

Every build-identity change writes `apply_enabled=false`. The build-9 agent must
complete a fresh successful dry-run for the canonical active folder with zero
moves and zero errors before the UI permits automatic organization again.

The release remains:

- Universal 2 (`arm64` and `x86_64`);
- ad hoc signed and non-notarized;
- distributed as an immutable GitHub prerelease with SHA-256 and GitHub build
  provenance;
- installable without Xcode, Command Line Tools, Homebrew, `sudo`, or Full Disk
  Access;
- offline for file organization, CLI, and LaunchAgent work;
- network-capable only through the explicit manual Update Center boundary from
  ADR-0011;
- unable to download, install, or roll back application code.

## Release sequence

1. Merge the versioned release preparation through protected `main`.
2. Create the annotated release tag only from the resulting `main` commit.
3. Let the Community workflow build, ad hoc sign, package, checksum, attest, and
   create a draft release.
4. Re-download and verify the draft DMG and checksum.
5. Publish the draft only after every check passes. GitHub then makes its assets
   and tag immutable.
6. Re-download the public immutable assets and independently verify checksum,
   provenance, bundle contents, architectures, code signature, build identity,
   and agent label.

## Gates

The tag must not be created unless:

1. all 92 self-tests pass;
2. the stability race passes 20/20;
3. debug, release, and Swift 6 warnings-as-errors builds pass;
4. CLI, folder chooser, event agent, LaunchAgent, uninstall, audit, demo, and
   Update Center policy gates pass;
5. the Universal 2 release pipeline verifies build 9 and all migration plists;
6. README, release notes, changelog, plists, CLI, app, and `VERSION` agree on
   1.3.0 and `v1.3.0-community.1`;
7. no test apply or undo touches a personal folder;
8. the internal manifest verifies the exact release-preparation tree.

The release is not complete until the published immutable assets are downloaded
and revalidated. A successful source PR or tag workflow alone is insufficient.

## Release-candidate evidence

The 1.3.0 release-preparation tree passed the complete local gate on macOS on
2026-08-14:

- 92/92 independent Swift self-tests;
- stability race repeated successfully 20/20 times;
- debug, release, and Swift 6 warnings-as-errors builds;
- CLI, folder chooser, FSEvents agent, LaunchAgent, uninstall, static audit,
  dry-run demo, security prototypes, and Update Center policy checks;
- Universal 2 verification for `arm64` and `x86_64`;
- ad hoc signature and Community build-9 agent verification;
- Community and development DMG construction and revalidation;
- an idle agent observation of 0.0% CPU with no CPU-time increase;
- zero personal-file moves and a dry-run result of zero moves and zero errors;
- internal manifest verification covering 132 files.

Publication and independent revalidation of the immutable public assets remain
pending and are intentionally separate from this source-tree validation.

## Consequences

- Users gain a discoverable update check without automatic execution or periodic
  network activity.
- Existing build-8 users must approve or enable the versioned build-9 background
  item if macOS requests it.
- Updating returns an existing apply configuration to dry-run; the user must
  explicitly re-enable it after the new agent passes verification.
- Automatic app installation and rollback remain future work and cannot be
  implied by the Update Center UI.
- Developer ID, notarization, Sandbox rollout, and physical Intel execution
  remain external gates.
