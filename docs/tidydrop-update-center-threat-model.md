# TidyDrop Update Center threat model

## Executive summary

The Update Center adds one narrow outbound trust boundary to an otherwise
offline runtime. Its highest-risk future operation would be replacing executable
code. Phase 1 deliberately stops before that boundary: it can discover a newer
strictly versioned release and open the official GitHub page, but cannot download
or install it.

The principal threats are a forged or compromised release feed, downgrade or
channel confusion, malicious response size/content, privacy leakage, and a
future failed update leaving the app or agent unusable. The phase-1 controls make
those threats low impact because release metadata cannot trigger code execution.
Automatic installation and rollback remain blocked pending the controls in
[ADR-0011](adr/0011-manual-update-center-and-recovery-boundary.md).

## Scope and assumptions

### In scope

- the AppKit Update Center in `Sources/TidyDropApp`;
- pure release parsing and selection policy in `Sources/TidyDropCore`;
- GitHub Releases metadata for `bugroo/tidydrop`;
- channel and version comparison;
- opening a fixed official release URL;
- future staged installation and application-bundle rollback boundaries;
- interaction with the bundled agent, apply/dry-run state, and TCC.

### Out of scope for phase 1

- automatic artifact download;
- application replacement or privileged installation;
- Sparkle or another updater framework;
- Developer ID/notarization claims;
- App Store distribution;
- remote rule feeds, analytics, telemetry, crash reporting, or file metadata
  transmission.

### Assumptions

- the official repository is `https://github.com/bugroo/tidydrop`;
- Community tags use `vX.Y.Z-community.N` and are GitHub prereleases;
- stable tags will use `vX.Y.Z` and will not be prereleases;
- GitHub and the local network can be unavailable or hostile;
- the user's Mac account may be compromised, in which case local UI integrity
  and browser actions cannot be guaranteed;
- ad hoc signatures do not provide durable publisher identity across releases.

No material unanswered question changes the phase-1 implementation. Developer
ID identity, signing-key custody, and recovery-helper design are explicit phase-2
or phase-3 gates.

## System model

```text
User gesture
    |
    v
TidyDrop.app / Update Center
    |  fixed HTTPS GET; no credentials or file metadata
    v
GitHub Releases API
    |
    v
bounded JSON -> strict parser -> channel/version policy
                                  |
                         newer valid release?
                           /             \
                         no               yes
                         |                 |
                  local status       fixed official URL
                                           |
                                           v
                                  user's default browser

TidyDropAgent ---- no network path ---- active folder
TidyDropCore  ---- no network path ---- journals / activity DB
```

The application is the only process allowed to make the request. The agent does
not import or invoke the Update Center, and no startup path schedules a check.

## Assets and security objectives

| Asset | Security objective |
| --- | --- |
| Application executable | Never execute code selected only by untrusted release metadata |
| Active folder and personal files | Never expose paths/content to the update service; never alter them during an app update |
| Configuration and journals | Preserve integrity and compatibility; never silently restore apply mode |
| Agent registration | Avoid duplicate/stale agents and prove a new dry-run after update |
| Update channel | Prevent Community/stable crossover and downgrade |
| User attention and consent | Network check and future installation must be explicit and accurately described |
| Signing keys and GitHub account | Prevent unauthorized release publication; keep secrets outside the repo and application |
| Battery and bandwidth | No periodic checks, background wakeups, or unbounded downloads |

## Threat actors

- an attacker controlling local DNS, proxying, or network availability;
- an attacker who compromises the GitHub repository or a maintainer account;
- a malicious contributor attempting to broaden the updater's endpoint or make
  checks automatic;
- a malicious or malformed GitHub release entry;
- another local unprivileged process racing staged files in a future updater;
- an accidental release operator publishing the wrong channel, version, or
  artifact;
- a future faulty TidyDrop build that cannot launch or migrate its agent/state.

## Trust boundaries and data flows

### Boundary 1: user gesture to network request

The check must originate from an Update Center button or menu action. Application
startup, FSEvents, the LaunchAgent, timers, and scheduled maintenance are not
trusted to initiate it.

### Boundary 2: TidyDrop to GitHub

Only a fixed HTTPS host, owner, repository, path, and bounded query are allowed.
No authorization, cookies, stored credentials, personal file data, active-folder
path, machine serial, hardware model, or analytics identifier crosses this
boundary.

### Boundary 3: JSON to application state

All fields are untrusted. Only a minimal schema is decoded. Tags are parsed with
a strict grammar and numeric bounds. Response URLs are not used for navigation.

### Boundary 4: app to browser

The app constructs an `https://github.com/bugroo/tidydrop/releases/tag/...` URL
from an already validated ASCII tag. It never embeds remote HTML.

### Boundary 5: future updater to filesystem and ServiceManagement

This boundary does not exist in phase 1. Before it is introduced, staging must
be private and no-follow, artifacts independently authenticated, replacement
atomic, the old bundle retained, state backed up, the agent re-registered, TCC
revalidated, and apply kept disabled.

## Abuse paths

### A1 — Feed compromise causes code execution

An attacker publishes a release pointing to a malicious DMG. In phase 1 the app
only displays a strict tag and opens the official release page; it does not fetch
or execute the asset. Residual risk is social engineering on the GitHub page.

### A2 — Downgrade or channel confusion

A release list includes an older build, a stable build in the Community feed,
or a superficially similar tag. Strict grammar, prerelease flags, channel policy,
and monotonic comparison reject it.

### A3 — Redirect to attacker-controlled website

A response supplies a malicious `html_url`. TidyDrop ignores it and constructs
the release URL from the fixed repository origin and validated tag.

### A4 — Oversized or malformed response consumes resources

The client applies timeouts and a hard response-size bound, accepts only a
successful HTTP response, and decodes a limited release count. Failure becomes a
bounded UI error; it cannot block the agent.

### A5 — Silent tracking and battery regression

A contributor schedules checks or adds the updater to the agent. Static audit
and tests restrict networking to one AppKit source and assert there is no startup
or agent call. The ephemeral session stores no cookies or persistent cache.

### A6 — Failed future update strands the app

The new bundle may fail before it can roll itself back. Phase 2 therefore
requires an out-of-process recovery component and retention of a verified prior
bundle. The new process is never the sole recovery authority.

### A7 — Update restores apply without proving access

Replacing the bundle may change an ad hoc identity and TCC decision. Every
future update must force dry-run, re-register the exact agent, and require a
fresh zero-move agent health result for the exact active folder. Returning to
apply requires explicit user confirmation.

### A8 — Rollback corrupts state or reverses personal operations

App rollback and file-operation undo are separate. A compatible versioned state
backup is required; personal-file journals are preserved and never replayed by
the updater.

## Required mitigations

| Control | Phase | Enforcement |
| --- | --- | --- |
| Manual-only check | 1 | UI action plus static no-startup/no-agent audit |
| Ephemeral, credential-free session | 1 | Update client configuration and source audit |
| Fixed official API and browser origins | 1 | Constants not supplied by response/configuration |
| Strict tag/channel parser | 1 | TidyDropCore unit regressions |
| Monotonic no-downgrade selection | 1 | TidyDropCore unit regressions |
| Response status/size/time bounds | 1 | Client code and static/integration checks |
| No artifact download/install APIs | 1 | Source audit |
| Immutable future releases | Release operation | Repository setting and release checklist |
| Independent signed manifest | 2 | Offline verifier foundation and negative tests implemented; release signing, pinned production key and rotation remain gated |
| Private no-follow staging, transport and inspection | 2 | Descriptor-bound writer, fixed-origin ephemeral streaming and authenticated read-only DMG/bundle inspection implemented outside shipping targets; production key/signing identity and installation remain gated |
| Prior verified bundle and state backup | 2 | Fault-injection integration tests |
| Out-of-process recovery | 2 | Kill/crash/power-loss tests |
| Developer ID + notarization + stable DR | 3 | codesign, spctl, stapler, and real-Mac gates |

## Risk register

| ID | Threat | Likelihood | Impact in phase 1 | Residual risk | Status |
| --- | --- | --- | --- | --- | --- |
| R1 | GitHub/repository compromise | Low–medium | Medium | Social engineering on official release page | Mitigated; signed manifests required before install |
| R2 | Downgrade/channel confusion | Medium | Low | Parser defect | Mitigated with strict tests |
| R3 | Oversized/malformed API response | Low | Low | Temporary app memory/latency | Mitigated with bounds |
| R4 | Privacy leakage | Low | Low | GitHub sees IP and request metadata | Accepted and disclosed |
| R5 | Background wakeup regression | Low | Low | Accidental future invocation | Guarded by source audit |
| R6 | Ad hoc TCC interruption after manual update | Medium | Medium | User approval may recur | Accepted for Community; dry-run gate required |
| R7 | Failed future auto-update | Not applicable | High | App/agent unavailable | Auto-install blocked pending phase 2 |
| R8 | State-incompatible rollback | Not applicable | High | Configuration/journal corruption | Auto-rollback blocked pending phase 2 |

## Secure design principles

- Minimize authority: release discovery cannot mutate the installation.
- Separate control planes: the background file agent has no updater network path.
- Fail closed: parsing or transport failure produces no update action.
- Make trust explicit: GitHub transport is not called artifact authentication.
- Preserve reversibility: future replacement retains a verified known-good bundle
  and compatible state before mutation.
- Require evidence: apply mode is never restored solely because an update or
  rollback process exited successfully.

## Testing priorities

1. strict parser tests for valid, malformed, huge, overflow, Unicode, draft, and
   cross-channel tags;
2. monotonic comparison tests for same version and downgrade resistance;
3. static checks for no startup, timer, agent, CLI, or Core network path;
4. response size, timeout, cancellation, non-HTTP, non-200, and malformed JSON
   tests at the client boundary;
5. fixed-origin navigation tests;
6. phase-2 fault injection at every transition: download, verify, backup,
   replace, register, launch, TCC check, commit, and rollback;
7. real-Mac update tests after macOS upgrades and permission revocation.

## Phase-2 staging progress

ADR-0015 adds a non-shipping streaming writer that anchors a private workspace
and partial artifact to open directory descriptors. It proves exclusive
creation/finalization, bounds, cancellation, injected disk exhaustion, symlink
rejection and late collision handling. It has no network, mount, extraction,
installation or Service Management path. R7 therefore remains open: the
current application still cannot install or roll back an update.

ADR-0017 adds the still non-shipping transport boundary. It constructs only the
official authenticated asset URL, accepts only the GitHub release-asset redirect
origin, uses an ephemeral credential-free session and streams into ADR-0015.
The writer now rejects the authenticated digest before finalizing a staged
artifact. Mock transport is injected per test session so regressions cannot
silently contact the real network. Extraction, bundle inspection and all
installation/recovery authority remain absent, so R7 remains open.

ADR-0018 completes the non-shipping U4 inspection boundary. It reopens and
rehashes the staged image, invokes only fixed `/usr/bin/hdiutil` operations with
bounded execution, mounts into private staging with read-only/no-browse/
no-auto-open controls and independently checks `MNT_RDONLY`. Descriptor-relative
walking permits only the exact image root, rejects unsafe bundle entry types and
enforces count/size/depth limits. Authenticated bundle identity/version, exact
Universal 2 app/CLI/agent binaries and strict nested all-architecture code
signature validation are mandatory. A real temporary DMG and negative identity,
symlink, thin-binary and tamper cases pass. No install/replacement/recovery API
exists, so R7 and R8 remain open.
