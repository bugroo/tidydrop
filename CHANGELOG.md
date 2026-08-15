# Changelog

## Unreleased

- Adds a separate non-shipping `tidydrop-recovery-helper` and a fail-closed
  destination-volume replacement protocol restricted to private
  `/private/tmp/TidyDropIntegration.*` fixtures. It uses descriptor-relative
  `RENAME_SWAP`, no-follow/beneath resolution, pre-swap device/inode pinning,
  directory fsync, strict bundle reinspection, interrupted-install recovery and
  symmetric rollback. It is not included in the app or DMG and has no authority
  over an installed application.
- Adds non-shipping descriptor-bound retention of the verified current
  `TidyDrop.app`, including pre/post source inspection, retained-copy inspection,
  complete tree digest, exact cleanup and refusal to overwrite prior recovery.
- Adds an fsync-backed external recovery journal state machine that forces
  dry-run, validates retained bundle/state digests, recovers one synchronized
  `.next` transition after interruption and rejects replay or invalid state
  transitions. App replacement and rollback execution remain disabled.
- Adds a non-shipping private recovery-state snapshot with a forced-dry-run
  configuration backup, SQLite online backup, schema/integrity verification,
  digests, private permissions, manifest-last publication, and exact cleanup at
  three injected interruption points. App retention and replacement remain
  disabled.
- Resolves SQLite source and destination paths from open descriptors before
  applying `SQLITE_OPEN_NOFOLLOW`, preventing macOS `/tmp` canonicalization from
  rejecting legitimate private state while preserving device/inode checks.
- Adds a non-shipping authenticated DMG inspector that revalidates staged
  identity and digest, verifies and mounts images read-only in private staging,
  rejects unsafe bundle trees, requires exact TidyDrop metadata and Universal 2
  app/CLI/agent binaries, and checks the complete code signature against an
  explicit requirement. Installation and replacement remain disabled.
- Limits the 20-iteration stability-race gate to its three exact regressions,
  avoiding redundant DMG creation and mounting while preserving the full test
  suite in the normal self-test gate.
- Adds a non-shipping fixed-origin update transport with an ephemeral,
  credential-free session, strict redirect/authentication policy, streaming
  into private staging, pre-finalization digest enforcement, cancellation and
  injected no-network regressions. Extraction and installation remain disabled.
- Makes the automated folder-chooser gate nonvisual by default, preventing a
  brief AppKit panel from flashing during validation and installation while
  retaining an explicit opt-in UI smoke test.
- Adds an isolated, non-shipping private update-staging writer with
  descriptor-anchored `0700`/`0600` storage, exclusive finalization, bounded
  streaming and cancellation/disk-full/collision regressions. Network download,
  extraction and installation remain disabled.

## 1.3.0 — Community Preview 2

- Adds a separate, non-shipping Ed25519 release-manifest verifier with canonical
  parsing, direct no-follow artifact hashing, replay/downgrade controls and
  negative regressions. Production key custody and updater activation remain
  gated.
- Adds Community build 10 with two-phase startup reconciliation: the first
  record is diagnostic and cannot authorize moving; only a second fresh run
  after FSEvents starts reports `agent_ready=true`.
- Migrates the build-9 registration without reusing its ad hoc service identity
  and keeps apply disabled until build 10 proves a ready zero-move run.

## 1.3.0 — Community Preview

- Adds a native manual Update Center under **TidyDrop → Software Updates…**.
- Uses one ephemeral, bounded request to the official `bugroo/tidydrop` release
  channel only after the user presses **Check for Updates**.
- Keeps file names, folder paths, cookies, credentials, telemetry, the CLI,
  TidyDropCore, and the LaunchAgent out of the update request.
- Adds strict Community/stable tag parsing, draft rejection, fixed-origin release
  links, response bounds, and downgrade/channel-confusion protection.
- Adds ADR-0011, a dedicated updater threat model, and explicit gates that block
  automatic installation and app rollback until artifacts and recovery are
  independently authenticated and fault-tested.
- Enables immutable GitHub releases for future publications; the earlier 1.2.0
  Community Preview remains outside that guarantee.
- Community build 9 migrates the build-8 agent registration before enabling the
  updated ad hoc-signed agent and returns every update to dry-run.

## 1.2.0 — Community Preview

- Adds the native three-pane AppKit workbench for active folder, activity,
  ordered rules, transaction history, and conservative undo.
- Replaces the bundled five-minute polling agent with a Foundation/CoreServices
  FSEvents process that reconciles at startup and uses one timer only while
  deferred candidates exist.
- Validates and consumes app-to-agent wake requests once using a private,
  source-bound, recent JSON signal until the signed XPC gate is complete.
- Adds a bounded SQLite activity index owned by the scheduled agent, with a
  read-only AppKit consumer, explicit schema migration, private permissions,
  verified WAL mode, and fail-soft UI behavior.
- Adds verified signed-XPC, designated-requirement, security-scoped bookmark,
  and minimal Sandbox-entitlement prototypes without enabling Sandbox in the
  Community release before persistent LaunchAgent access is proven.
- Adds isolated event, burst, idle-resource, rule-edit, history, and undo
  regressions without running apply or undo against personal folders.
- Community build 8 removes immediate `NoDefer` delivery and lets FSEvents
  coalesce background changes for fewer wakeups. It migrates build 7, build 6,
  and build 5 registrations before enabling the updated agent.

## 1.1.2 — Community Preview

- Rechecks an already registered background agent automatically when the app
  opens, without attempting a duplicate `SMAppService.register()` call.
- Binds background verification to a recent successful run for the exact active
  folder and expected mode; older records remain readable but cannot authorize
  automatic moving without a fresh run.
- Adds a resizable AppKit setup window with clearer progress, native path
  presentation, last-run feedback, contextual background controls, and one
  automatic-organization toggle.
- Adds a native application icon and verifies that the packaged bundle declares
  and contains the regular `.icns` resource.
- Community build 6 uses a new versioned agent label and safely migrates the
  prior build-5 service before registration.
- Adds two independent regressions for source-bound verification, freshness,
  expected execution mode, and zero-move dry-run safety.

## 1.1.1 — Community Preview

- Fixed the installed CLI's background-agent status check so it recognizes the
  bundled `SMAppService` agent instead of reporting a false `not_installed`.
- Rejects `/Applications`, the system-installed TidyDrop bundle, and descendants
  as active-folder scopes when they could contain or overlap application code.
- Added runtime-coherence regressions for bundled-agent status and protected
  system application paths.
- Added a bundle-local ServiceManagement control path so an updater can
  unregister and re-register the embedded agent after replacing an ad hoc build,
  then require a new zero-move dry-run before restoring automatic mode.
- Community build 5 uses a versioned LaunchAgent registration to migrate once
  from the ad hoc build-4 code requirement. Developer ID builds retain the
  stable production agent label.
- Refreshed the public README with a direct Community Preview download,
  privacy-first product summary, restrained visual cues, and contributor entry
  points.
- Public validation evidence now removes local user paths and hostnames before
  it is committed; the static audit fails closed if those details or common
  credential patterns reappear.
- DMG verification now retries a temporarily busy read-only mount and never
  attempts to clean the mount directory while it remains attached.

## 1.1.0 — Community Preview

- Added a free Community Preview channel: ad hoc signed Universal 2 DMG,
  SHA-256, GitHub build provenance, draft re-download verification, and
  prerelease-only publication.
- Added an in-app Community Preview warning and a second confirmation before
  automatic moving can be enabled.
- Added a native AppKit onboarding application with a separate Foundation-only background agent registered through `SMAppService`.
- Added a Universal 2 DMG pipeline with Developer ID, app and DMG notarization, stapling, Gatekeeper verification, checksum, and post-publication revalidation.
- Phase 2 started with an accepted ADR and testable backlog for a notarized DMG and native, shell-free onboarding.
- Public README rewritten in English around the user problem, installation, privacy, and safe operation.
- Eventful scheduled passes now always record balanced `run_started` and `run_finished` boundaries while true no-op passes remain silent.
- Added a sanitized overnight runtime audit with transaction, log, permission, and resource evidence.
- Build reproducible como procedimiento para un bundle Universal 2 `arm64` + `x86_64`.
- Gates separados para firma ad hoc de desarrollo y Developer ID de distribución.
- Hardened Runtime, timestamp, Team ID, bundle ID, Gatekeeper y ticket de notarización verificados de forma fail-closed.
- Pipeline de notarización con `notarytool --wait` y aceptación explícita antes de grapar.
- GitHub Actions de solo lectura, sin secretos en PR y con checkout fijado a SHA completo.
- Empaquetado DMG con checksum y revalidación después de montar.

## 1.0.2 — 2026-08-12

- Rebranding completo a TidyDrop, bundle `com.local.tidydrop` y CLI `tidydrop`.
- `doctor.sh` selecciona explícitamente el SDK de macOS con Apple Command Line Tools.
- Snapshots críticos basados en `lstat(2)` fresco y mtime con nanosegundos.
- Comprobaciones separadas antes, durante y justo antes del movimiento.
- Carpeta activa única configurable con CLI y selector nativo AppKit.
- Cambio de carpeta vuelve siempre a dry-run y preserva transacciones.
- Estado seguro `source_unavailable` para volúmenes ausentes.
- Claves TCC para carpetas personales, volúmenes extraíbles y de red.
- Regresiones ampliadas y repetición de carreras.
- Auditoría de hardening: apply/undo con rename exclusivo anclado a descriptores.
- Lock, logs y JSON protegidos con `O_NOFOLLOW`, propiedad/permisos y escrituras atómicas privadas.
- Lecturas JSON, reglas y sonda MIME acotadas contra consumo accidental de recursos.
- Caché privada de planes dry-run: planes sin cambios ya no repiten la sonda ni hacen crecer logs.
- Gate adicional compatible con el modo de lenguaje Swift 6 estricto.

## Origen 1.0.1

Esta versión deriva de Download Steward 1.0.1. La evidencia baseline conservó dos fallos reproducibles en macOS: el probe de `swiftc` sin SDK explícito y metadatos Foundation cacheados durante estabilidad/undo.
