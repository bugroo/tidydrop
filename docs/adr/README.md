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
| [ADR-0006](0006-appkit-workbench-information-architecture.md) | Accepted for 1.2 implementation | Native workbench for active folder, activity, rules, history, and conservative undo |
