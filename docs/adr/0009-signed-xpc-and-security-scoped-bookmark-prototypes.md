# ADR-0009: Signed XPC and security-scoped bookmark prototypes

- Status: Prototype accepted; release rollout blocked by integrated sandbox gate
- Date: 2026-08-14
- Decision makers: project owner and Codex
- Related: [ADR-0001](0001-native-macos-application-architecture.md), [ADR-0007](0007-event-driven-fsevents-agent.md)

## Context

The current app and agent coordinate through private files in Application
Support. That is safe for the Community Preview but does not establish a
cryptographically authenticated command channel or persistent sandbox access
to an arbitrary user-selected folder.

## Prototype decision

The macOS 13 Command Line Tools SDK supports
`NSXPCConnection.setCodeSigningRequirement(_:)` for arm64 and x86_64. TidyDrop
therefore keeps signed XPC as the target channel.

The prototype derives a peer's designated requirement from signed code using
Security.framework rather than hard-coding a Team ID that does not yet exist.
An anonymous XPC integration applies that requirement at both endpoints. The
real requirement accepts a request and an impossible peer identifier is
rejected. A Developer ID release will additionally pin the expected Team ID and
bundle identifiers as a release gate.

The bookmark prototype creates an app-scoped security-scoped bookmark for a
real temporary directory, resolves its canonical URL, reports staleness, starts
access, and balances every successful start with a stop. Bookmark bytes are
bounded and never enter logs, evidence, Git, SQLite, or the public repository.

Two minimal entitlement files define the intended boundary:

- the UI receives App Sandbox, app-scoped bookmarks, and user-selected
  read/write access;
- the agent receives App Sandbox and app-scoped bookmarks, but no Powerbox or
  network entitlement.

The entitlement prototype is ad hoc signed and inspected on both architectures
without applying those entitlements to a release bundle.

## State ownership direction

The sandboxed agent should own runtime configuration, SQLite, journal, and
bookmark storage inside its container. The app should request reads and
mutations through authenticated XPC. This avoids adding an App Group solely to
preserve the current shared-file layout. An App Group remains rejected unless
an integrated prototype proves it necessary.

## Why rollout remains blocked

Passing a bookmark round trip outside the sandbox and embedding entitlement
keys do not prove that an `SMAppService` LaunchAgent retains access after the UI
exits, after logout/restart, on a removable volume, or after a stale bookmark.
Apple also notes that different signing requirements can trigger new container
consent. The Community Preview is ad hoc signed, so its identity is not stable
enough for the final trust and TCC continuity model.

Consequently, release signing scripts intentionally do not apply the prototype
entitlements. The existing private one-shot request signal remains the stable
channel until the integrated agent test below passes.

## Integrated rollout gates

1. The app obtains a folder through a real `NSOpenPanel` and sends only the
   bookmark over mutually authenticated XPC.
2. The sandboxed agent stores the bookmark privately, resolves it after the app
   exits and after login, and balances scoped access.
3. The agent renews stale bookmarks through the UI without silently changing
   the active folder or enabling apply.
4. External/removable and network-volume unavailable states remain fail-closed
   and recover without creating paths.
5. A client signed with another identity is rejected by the real Mach service,
   not only by the anonymous prototype.
6. The complete app and agent are signed with stable Developer ID identities,
   notarized, and verified on a clean Mac before Sandbox becomes a release
   invariant.

## References

- [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)
- [NSXPCConnection code-signing requirement](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:))
- [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
