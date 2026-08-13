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
| [ADR-0002](0002-distribution-updates-and-tcc-continuity.md) | Aceptado; fase 1 en implementación | Distribución firmada/notarizada, actualizaciones manuales verificadas y continuidad TCC |
