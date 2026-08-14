# Registro de decisiones de arquitectura

Las decisiones que cambian arquitectura, seguridad, distribución, permisos o ciclo de vida de TidyDrop se registran aquí antes de implementarse.

## Convención

- Una decisión aceptada no se reescribe para cambiar su significado.
- Un cambio posterior crea otro ADR que indica qué decisión reemplaza.
- Cada ADR separa el estado observado, la decisión aprobada, los gates y las consecuencias.
- Un ADR aceptado no equivale a una implementación terminada: los gates deben aportar evidencia real.

## Índice

| ADR | Estado | Decisión |
| --- | --- | --- |
| [ADR-0001](0001-native-macos-application-architecture.md) | Dirección aceptada; condicionada a prototipos | Aplicación macOS AppKit-first, agente mínimo FSEvents y núcleo compartido |
| [ADR-0002](0002-distribution-updates-and-tcc-continuity.md) | Aceptado; readiness de fase 1 implementada, gates externos pendientes | Distribución firmada/notarizada, actualizaciones manuales verificadas y continuidad TCC |
| [ADR-0003](0003-end-user-installation-experience.md) | Aceptado; implementación pendiente | DMG notarizado e incorporación nativa sin shell para usuarios finales |
| [ADR-0004](0004-community-preview-without-developer-id.md) | Aceptado | Prerelease gratuita, ad hoc y verificable mientras no exista Developer ID |
| [ADR-0005](0005-source-bound-relaunch-verification-and-setup-ui.md) | Aceptado e implementado en 1.1.2 | Verificación al reabrir vinculada a la carpeta y UI de configuración simplificada |
| [ADR-0006](0006-appkit-workbench-information-architecture.md) | Accepted and implemented in 1.2.0 | Native workbench for active folder, activity, rules, history, and conservative undo |
| [ADR-0007](0007-event-driven-fsevents-agent.md) | Accepted and implemented in 1.2.0 | Event-driven FSEvents agent with reconciliation and one stability timer |
| [ADR-0008](0008-agent-owned-sqlite-activity-index.md) | Accepted and implemented in 1.2.0 | Agent-owned, bounded SQLite activity index with a read-only AppKit consumer |
| [ADR-0009](0009-signed-xpc-and-security-scoped-bookmark-prototypes.md) | Prototype accepted; integrated gate pending | Signed XPC peer rejection, scoped bookmarks, and minimal Sandbox entitlements |
| [ADR-0010](0010-community-1.2-release-boundary.md) | Accepted | Ship the completed 1.2 workbench and event agent while keeping Developer ID/Sandbox claims gated |
| [ADR-0011](0011-manual-update-center-and-recovery-boundary.md) | Accepted; phase 1 implemented and validated | Manual private update discovery now; authenticated staged install and recovery remain gated |
| [ADR-0012](0012-community-1.3-release-boundary.md) | Accepted, published, and independently revalidated | Ship the manual Update Center as 1.3.0 Community Preview with a versioned build-9 agent migration |
| [ADR-0013](0013-offline-ed25519-release-manifest-foundation.md) | Accepted and implemented as a non-shipping foundation | Canonical offline Ed25519 artifact verification now; production key custody and updater activation remain gated |
| [ADR-0014](0014-two-phase-agent-startup-readiness.md) | Accepted, published, and verified on the installed Mac | Persist non-authorizing startup diagnostics before FSEvents and authorize only after a ready second reconciliation |
| [ADR-0015](0015-private-update-staging-foundation.md) | Accepted and implemented as a non-shipping foundation | Descriptor-bound private staging now; network, extraction, install and activation remain gated |
| [ADR-0016](0016-nonvisual-automated-folder-chooser-validation.md) | Accepted and implemented | Automated gates validate the native selector contract without opening UI; the real panel smoke test requires explicit opt-in |
| [ADR-0017](0017-fixed-origin-authenticated-update-transport.md) | Accepted and implemented as a non-shipping foundation | Fixed-origin ephemeral transport streams authenticated bytes into private staging; extraction and installation remain gated |
