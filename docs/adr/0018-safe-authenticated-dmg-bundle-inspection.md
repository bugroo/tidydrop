# ADR-0018: Safe authenticated DMG and bundle inspection foundation

- Status: Accepted and implemented as a non-shipping foundation
- Date: 2026-08-15
- Decision makers: project owner and Codex
- Related: [ADR-0013](0013-offline-ed25519-release-manifest-foundation.md), [ADR-0015](0015-private-update-staging-foundation.md), [ADR-0017](0017-fixed-origin-authenticated-update-transport.md)

## Context

U4 could authenticate and privately stage exact release bytes, but a valid DMG
digest alone did not prove that its mounted contents were a safe, correctly
identified TidyDrop bundle. Disk-image filesystems, bundle metadata, Mach-O
headers, symlinks and code signatures all remain untrusted inputs after the
download completes.

Inspection must not become installation authority. It must not launch Finder,
copy an app to `/Applications`, register a service, relaunch code or make the
current product appear to have an updater before production key custody and
recovery are ready.

## Decision

Add a separate `TidyDropUpdateInspection` module that depends on the offline
authenticated-manifest and staging module. No shipping target imports it.

Before invoking DiskImages, the inspector reopens the staged artifact beneath
its private `0700` workspace with `openat` and `O_NOFOLLOW`. The artifact must
remain a single-link `0600` regular file owned by the current user. Device,
inode and byte count must match `StagedUpdateArtifact`; SHA-256 is recomputed
from the descriptor and must match the authenticated manifest. Stable metadata
is checked before and after use.

`/usr/bin/hdiutil` is invoked directly, never through a shell, with a minimal
environment, null standard input/output/error and bounded execution times. The
image checksum is verified first. Attach uses explicit `-readonly`, `-verify`,
`-nobrowse`, `-noautoopen`, `-owners off` and a private mountpoint inside the
staging workspace. The mounted filesystem must independently report
`MNT_RDONLY`. Detach never uses `-force`.

The image root must contain exactly:

- `TidyDrop.app` as a real directory; and
- `Applications` as the exact conventional symlink to `/Applications`.

No symlink is permitted inside `TidyDrop.app`. Descriptor-relative physical
walking rejects cross-device directories, hard-linked regular files, devices,
sockets, FIFOs, traversal, directory cycles and excessive depth. Entry count
and total regular-file bytes are bounded before metadata parsers or code-signing
checks can authorize the bundle.

The bounded `Info.plist` must declare an `APPL` bundle with the authenticated
bundle identifier and marketing version. `CFBundleExecutable` must be a strict
leaf name. The main executable, `Contents/Resources/tidydrop` and
`Contents/Resources/tidydrop-agent` must each contain exactly `arm64` and
`x86_64`; Mach-O fat headers and slice ranges are parsed without executing the
files.

Finally, `SecStaticCodeCheckValidity` validates the whole app against an
explicit caller-supplied signing requirement with all-architecture, strict and
nested-code flags. The requirement is mandatory and bounded. A production
Developer ID requirement is not present in the product yet; that remains a U3
and U7 activation gate.

## Test isolation

The public entry point accepts only an authenticated manifest and a finalized
staged artifact. An `@_spi(Testing)` entry point inspects a supplied mounted root
so negative filesystem and signature cases do not require a new DMG per case.

The end-to-end regression still builds a real minimal Universal 2 app using
Apple Command Line Tools, ad hoc signs its app/CLI/agent, creates a DMG under
`/private/tmp`, authenticates and stages the image with an ephemeral Ed25519
key, mounts it read-only, validates it and confirms that the mountpoint is gone.

Negative regressions cover forged staged identity, unexpected image entries,
bundle symlinks, wrong bundle identity, thin main or agent binaries and
post-signing resource tampering.

The release-pipeline gate also passes the complete generated Community DMG back
through this authenticated inspector, rather than relying only on the minimal
fixture bundle.

## Activation boundary

This module returns immutable inspection evidence only. It has no API for
copying, replacing, installing, launching, registering, relaunching or rolling
back an app. The installed build and public Community DMG are unchanged.

U4's technical foundation is complete with ephemeral test keys. Product
activation remains blocked until U3 supplies approved production key custody
and U7 supplies a stable Developer ID signing requirement. U5 must still build
out-of-process recovery and atomic replacement before an update can be applied.

## Consequences

- A downloaded artifact cannot advance merely because TLS or GitHub accepted
  it; manifest authentication, staged digest, filesystem policy, bundle identity,
  Universal 2 structure and code-signing requirement must all agree.
- Mounting any disk image still exercises Apple's DiskImages/filesystem parser.
  Authentication before mount, checksum verification and read-only attachment
  reduce exposure but cannot eliminate vulnerabilities in the operating system.
- Exact top-level layout intentionally rejects customized DMGs with backgrounds,
  extra documentation or additional apps.
- Community ad hoc signatures are suitable only for the isolated regression;
  they are not a production updater identity.

## References

- [Apple Security: SecStaticCodeCheckValidity](https://developer.apple.com/documentation/security/secstaticcodecheckvalidity%28_%3A_%3A_%3A%29)
- [Apple Security: static code validation flags](https://developer.apple.com/documentation/security/static-code-validation-flags)
- [Apple: Building a universal macOS binary](https://developer.apple.com/documentation/apple-silicon/building-a-universal-macos-binary)
- [Apple: Information Property List](https://developer.apple.com/documentation/bundleresources/information-property-list)
- Local macOS `hdiutil(1)` manual for `verify`, read-only attachment, mountpoint,
  browsing, auto-open and owners behavior
