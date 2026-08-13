# Changelog

## Unreleased

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
