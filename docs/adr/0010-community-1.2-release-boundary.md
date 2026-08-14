# ADR-0010: TidyDrop 1.2 Community release boundary

- Status: Accepted
- Date: 2026-08-14
- Decision makers: project owner and Codex
- Related: [ADR-0006](0006-appkit-workbench-information-architecture.md), [ADR-0007](0007-event-driven-fsevents-agent.md), [ADR-0008](0008-agent-owned-sqlite-activity-index.md), [ADR-0009](0009-signed-xpc-and-security-scoped-bookmark-prototypes.md)

## Context

The AppKit workbench, event-driven agent, and derived SQLite activity index are
complete and pass the local macOS validation matrix. The signed-XPC, bookmark,
and Sandbox work is intentionally a prototype: an ad hoc Community signature
does not provide the stable identity required for durable container, XPC, and
TCC continuity.

## Decision

Release these completed features as TidyDrop 1.2.0 Community Preview while
keeping App Sandbox and the prototype entitlements disabled in distributed
bundles.

The Community agent label advances to
`io.github.bugroo.tidydrop.agent.community.v7`. The app includes migration
metadata for build 6 and build 5, unregisters an enabled older Community agent
before registering build 7, and returns automatic moving to dry-run whenever
the installed build identity changes.

The Community release remains:

- ad hoc signed and non-notarized;
- Universal 2 (`arm64` and `x86_64`);
- local-only at runtime;
- installable without Xcode, Homebrew, `sudo`, or Full Disk Access;
- a GitHub prerelease with SHA-256 and build provenance;
- fail-closed when the background agent cannot prove a fresh zero-move preview
  for the exact active folder.

## External release gates

Only these claims remain outside the evidence available to this project:

1. Developer ID signing and Apple notarization require an active Apple
   Developer Program identity and credentials.
2. Native execution and installation on physical Intel hardware require access
   to an Intel Mac. Both slices are compiled and statically verified locally,
   but only the host architecture can execute in this session.

Sandbox rollout belongs to the Developer ID gate because the final XPC peer
requirements, persistent bookmarks, containers, and TCC continuity all depend
on a stable signed identity. Until that external gate exists, Community builds
continue using the already verified non-Sandbox security boundary.

## Consequences

- Users gain the native workbench and lower-wakeup FSEvents agent now.
- Existing Community users may see macOS request approval for the new build-7
  background item or Files & Folders access again.
- Upgrading never restores apply automatically; the user must review the new
  preview and explicitly enable automatic organization.
- No release text may claim Developer ID, notarization, Sandbox enforcement, or
  physical Intel execution before those gates produce real evidence.
