# TidyDrop maintainer handoff

**Current as of:** 2026-08-16

**Authoritative remote:** `https://github.com/bugroo/tidydrop`

**Authoritative branch:** `origin/main`

**Code-bearing baseline commit:** `fc8f3a2c6d9448314816f33d507cb7321c33825f`

Read this document before continuing update, recovery, release, installation,
or runtime work. The repository contains three different states that must not
be conflated.

## Current state

| Layer | Verified state |
| --- | --- |
| Public download | `v1.3.0-community.2`, TidyDrop 1.3.0 build 10, Universal 2, ad hoc signed and not notarized |
| Public release evidence | Checksum, GitHub attestation, mounted-DMG verification and bundle self-check pass in [`public-release-1.3.0-community.2.txt`](evidence/public-release-1.3.0-community.2.txt) |
| Repository `main` | Includes PR #30 and PR #31: schema-bound dry-run state restoration plus real helper death/relaunch coverage |
| Installed-Mac audit | TidyDrop 1.3.0 build 10 was healthy in apply mode on Downloads at the last read-only audit; see [`RUNTIME-AUDIT-2026-08-14-1.3.0-BUILD10.md`](RUNTIME-AUDIT-2026-08-14-1.3.0-BUILD10.md) |
| Shipping boundary | PR #30/#31 recovery code is a non-shipping foundation. It is not in the installed app or current DMG and does not authorize automatic updates |

The public Community Preview remains a manual-download release. It must not be
described as Developer ID signed, notarized, automatically updating, or capable
of automatic application rollback.

## Completed and verified

- Manual update discovery is explicit, bounded, fixed to the official GitHub
  repository and absent from the agent, CLI, and core engine.
- Release-manifest verification, private staging, authenticated transport,
  read-only DMG inspection, bundle retention, atomic replacement and state
  restoration foundations exist outside shipping targets.
- The helper survives and reconciles real `SIGKILL` at all four durable bundle
  replacement boundaries and all five durable state-restoration boundaries.
- The process-death matrices repeat five times: 20 bundle kills plus 25 state
  restoration kills.
- State rollback always disables apply and never invokes file-operation undo.
- The complete repository validation records 132 PASS, 0 SKIP, 0 FAIL and a
  verified 178-file manifest.
- PR #31 passed `Universal 2 and safety gates` and was merged into `main` as
  `fc8f3a2`.
- Automated folder-chooser tests are nonvisual. ADR-0016 fixed the transient
  window flash; the LaunchAgent executes the Foundation-only agent, not AppKit.

Primary evidence:

- [`UPDATE-ROADMAP.md`](UPDATE-ROADMAP.md)
- [`ADR-0023`](adr/0023-schema-bound-dry-run-state-restoration.md)
- [`ADR-0024`](adr/0024-state-restoration-process-kill-harness.md)
- [`self-tests.txt`](evidence/self-tests.txt)
- [`recovery-helper-kill-relaunch.txt`](evidence/recovery-helper-kill-relaunch.txt)
- [`state-restoration-kill-relaunch.txt`](evidence/state-restoration-kill-relaunch.txt)
- [`validation-result.txt`](evidence/validation-result.txt)

## Mandatory restart procedure

This checkout contains a historical local branch named `main` whose ancestry is
not the public GitHub `main`. Do not merge, reset, or replace it. A new terminal
must start from the remote reference:

```sh
git fetch origin --prune
git switch -c <focused-branch-name> origin/main
./scripts/verify-manifest.sh
```

Before editing, inspect `README.md`, `Package.swift`, this handoff, the relevant
ADR, `docs/UPDATE-ROADMAP.md`, the three GitHub workflows, and the actual test
commands under `scripts/`. Do not invent substitute gates.

## What remains

| Gate | Status and required decision/evidence |
| --- | --- |
| U3 production metadata | Approve a production key-custody procedure, sign immutable release manifests, pin the production public key, and rehearse rotation/revocation |
| U4 activation | Blocked until U3 production identity and the stable signing requirement are satisfied |
| U5 installed recovery | Real destination staging, stable helper signing, installed-scope authority and a real reboot/host-shutdown recovery matrix remain |
| U6 updater orchestration | Connect the exact old-agent unregister, atomic bundle/state protocol, exact new-agent registration, independent app/agent folder-access checks, zero-move dry-run, and explicit apply confirmation |
| U7 distribution | Requires Apple Developer Program identity, Developer ID, notarization/stapling, a physical Intel test and the full TCC/macOS-upgrade matrix |

There is no remaining autonomous step that may safely activate the updater on
the installed Mac. Continue only after the missing authority or test environment
for the selected gate is explicit. Until then, safe work is limited to isolated
non-shipping foundations, documentation, static controls, and tests under the
existing private `/private/tmp/TidyDropIntegration.*` boundary.

## Non-negotiable safety boundaries

- Never enable automatic update or rollback based only on the current
  foundations.
- Never import update/recovery SPI into the shipping app, CLI, core, or agent.
- Never run apply or undo tests in a personal folder. Use only the repository's
  `/private/tmp/TidyDropIntegration.*` fixtures.
- Never use `sudo`, Full Disk Access, direct TCC database changes, Gatekeeper
  disabling, or a remote `curl | sh` installer.
- Never publish signing keys, credentials, machine-specific paths, or private
  runtime data.
- Never claim a DMG was updated unless a new immutable GitHub Release was built,
  re-downloaded, reverified and published by its workflow.
- Changing the active folder must always return TidyDrop to dry-run.

## Next implementation once prerequisites exist

The next product milestone is U6 orchestration, not another UI feature. Its
minimum transaction is:

1. prove the exact current bundle, agent, configuration and recovery snapshot;
2. disable apply and unregister only the exact old bundled agent;
3. perform authenticated replacement through the external recovery protocol;
4. register only the exact newly installed agent;
5. verify app and agent access independently against the exact active folder;
6. require a fresh dry-run with `moved=0` and `errors=0`;
7. restore apply only after an explicit user confirmation;
8. on any failure, reconcile or roll back from a fresh helper process and remain
   in dry-run.

Do not start installed-scope implementation until stable signing and the real
reboot test plan are approved. A simulated process kill is already covered and
must not be presented as a reboot test.

## Verification required before every PR

At minimum, run the real repository commands relevant to the change. For any
update/recovery change, the final gate is:

```sh
./scripts/validate-project.sh
git diff --check
./scripts/verify-manifest.sh
```

The validation builds debug, release, Swift 6 and both Universal 2
architectures; executes the complete self-test, race, CLI, LaunchAgent,
uninstall, update/recovery and process-kill suites; builds and verifies the
development and Community Preview DMGs; updates evidence; and regenerates the
manifest. Do not declare completion when any gate fails.
