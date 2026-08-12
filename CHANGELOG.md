# Changelog

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
