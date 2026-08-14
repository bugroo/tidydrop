# ADR-0017: Fixed-origin authenticated update transport foundation

- Status: Accepted and implemented as a non-shipping foundation
- Date: 2026-08-15
- Decision makers: project owner and Codex
- Related: [ADR-0011](0011-manual-update-center-and-recovery-boundary.md), [ADR-0013](0013-offline-ed25519-release-manifest-foundation.md), [ADR-0015](0015-private-update-staging-foundation.md)

## Context

ADR-0013 authenticates canonical release metadata and ADR-0015 provides a
private descriptor-bound streaming sink. U4 still lacked a transport that could
connect those boundaries without persisting cookies, credentials, caches or a
temporary download outside controlled staging.

The release feed, redirect targets, response headers and body are untrusted.
The transport must not accept a caller-provided arbitrary URL, follow a redirect
to an arbitrary host, buffer the full DMG in memory, or make transport success
equivalent to authorization to extract or install.

## Decision

Add `FixedOriginUpdateTransport` inside a separate gated
`TidyDropUpdateTransport` module that depends on the offline
`TidyDropUpdateSecurity` module.

The initial URL is derived only from authenticated manifest fields and the
fixed repository path:

```text
https://github.com/bugroo/tidydrop/releases/download/<authenticated-tag>/<authenticated-artifact>
```

Redirects are limited to three hops and only the fixed GitHub origin or GitHub's
release-asset origin. Every accepted redirect is rebuilt as a GET request with
only fixed `Accept`, `Accept-Encoding: identity`, and non-identifying
TidyDrop transport headers. Credentials, cookies, bodies and response-supplied
authorization headers are not propagated.

The session uses `URLSessionConfiguration.ephemeral`, no URL cache, cookie
store or credential store, one connection per host, bounded request/resource
timeouts and no connectivity waiting. Only default TLS server-trust handling is
allowed; all other authentication challenges fail closed.

The response must be HTTP 200. A positive `Content-Length`, when present, must
equal the authenticated manifest length. Body callbacks stream directly into
`PrivateUpdateStagingWriter`; its independent signed length bound remains
authoritative when a server omits the header or uses transfer framing.

ADR-0015 is strengthened to hash the exact bytes successfully written and
compare them with the authenticated SHA-256 before the partial file can receive
its final name. A digest mismatch removes only the app-owned partial workspace.

Cancellation cancels the data task and asks the staging writer to remove its
partial state. HTTP, redirect, authentication, timeout and staging failures do
not touch the installed app.

## Test isolation

The production entry point cannot inject URL loading protocols. A separate
`@_spi(Testing)` entry point accepts protocol classes only for the independent
self-test target. Tests use that explicit session configuration and never call
global `URLProtocol.registerClass`, preventing a failed mock from silently
reaching GitHub.

Static gates reject use of the testing SPI from app, agent, Core or CLI targets.

## Activation boundary

No shipping target imports `TidyDropUpdateSecurity` or
`TidyDropUpdateTransport`. This transport has no UI
action, background schedule, production public key, mount, extraction, bundle
inspection, installation, relaunch or application replacement path.

U4 remains incomplete until an authenticated artifact can be inspected after
safe extraction: entry counts/sizes, traversal and symlink rejection, expected
bundle structure and identifier, Universal 2 architectures and the required
code-signing identity must all pass before U5 may begin.

## Gates

1. Swift 6 warnings-as-errors build passes.
2. The official URL is constructed from authenticated fields only.
3. External redirects and non-server-trust authentication are rejected.
4. Accepted redirects cannot propagate authorization or cookie headers.
5. Mocked multi-chunk transport reaches private staging with exact bytes.
6. Non-200 response, cancellation and digest mismatch remove partial staging.
7. Test traffic is injected per session and cannot fall through to real GitHub.
8. App, Core, CLI and LaunchAgent remain free of the new transport.
9. Full validation and CI remain green.

## Consequences

- U4 now has an authenticated, bounded transport-to-staging path suitable for
  future integration after production key custody is approved.
- Normal TidyDrop runtime, installed app and Community DMG remain unchanged.
- The GitHub release-asset host is an explicit availability dependency, but
  artifact integrity still depends on the independent Ed25519 manifest and
  digest rather than TLS or repository metadata alone.
- Download resumption is intentionally absent; cancellation restarts a future
  manual download instead of persisting unauthenticated resume data.

## References

- [Apple Foundation: ephemeral URLSessionConfiguration](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/ephemeral)
- [Apple Foundation: URLSessionTaskDelegate](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate)
- [Apple Foundation: URLSessionDataDelegate](https://developer.apple.com/documentation/foundation/urlsessiondatadelegate)
- [GitHub: release assets](https://docs.github.com/en/rest/releases/assets)
