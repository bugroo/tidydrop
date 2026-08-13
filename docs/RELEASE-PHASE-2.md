# Fase 2: instalación nativa para usuarios finales

## Objetivo

Convertir la cadena preparada en fase 1 en una instalación real que una persona
pueda completar sin Terminal ni herramientas de desarrollo. El canal objetivo
es un DMG firmado y notarizado con incorporación dentro de `TidyDrop.app`, según
[ADR-0003](adr/0003-end-user-installation-experience.md).

## Estado de entrada

Completado:

- PR de readiness fusionado y CI de Universal 2/safety gates verde;
- build Universal 2 y modos de firma separados;
- notarización y empaquetado fail-closed implementados;
- instalación de desarrollo 1.0.2 verificada en este Mac;
- auditoría del runtime y corrección de límites de eventos publicada;
- rama `main` protegida con el check obligatorio.

Pendiente externo o de producto:

- bundle ID definitivo `io.github.bugroo.tidydrop` fijado;
- Apple Developer Program, Team ID y certificado Developer ID;
- notarización real;
- incorporación AppKit y agente incluido con `SMAppService`;
- ejecución en Intel y prueba en un Mac limpio sin herramientas de desarrollo.

## Backlog priorizado

### P2-1 · Fijar identidad pública

Como usuario, quiero que cada versión conserve la misma identidad verificable,
para que macOS pueda atribuir correctamente la aplicación y sus permisos.

Criterios de aceptación:

- bundle ID definitivo `io.github.bugroo.tidydrop` y agente `io.github.bugroo.tidydrop.agent` documentados;
- Team ID y designated requirement fijados como gates;
- migración explícita desde `com.local.tidydrop`;
- ninguna credencial o certificado dentro del repositorio.

Estado: bundle IDs decididos; Team ID y Developer ID pendientes.

Estimación: 2 puntos. Dependencia restante: Apple Developer Program. Prioridad:
bloqueante.

### P2-2 · Incorporación nativa sin shell

Como receptor, quiero instalar y configurar TidyDrop desde la app, para no tener
que ejecutar comandos que no comprendo.

Criterios de aceptación:

- DMG con `TidyDrop.app` y flujo claro de copia/apertura;
- selección de carpeta mediante `NSOpenPanel`;
- agente incluido y registrado mediante `SMAppService`;
- primera pasada en dry-run con resultado visible;
- cancelar no modifica la carpeta ni activa movimientos;
- sin `sudo`, Full Disk Access ni herramientas de desarrollo.

Estimación: 5 puntos. Dependencias: P2-1 y prototipo de ADR-0001. Prioridad:
alta.

### P2-3 · Firma, notarización y DMG final

Como receptor, quiero que Gatekeeper verifique TidyDrop, para detectar un
artefacto alterado o sin identidad aprobada.

Criterios de aceptación:

- Developer ID y Hardened Runtime verificados en todos los componentes;
- notarización `Accepted` y ticket grapado;
- `spctl --assess` aprobado sobre el artefacto descargado;
- SHA-256, manifiesto y procedencia publicados con la release;
- fallo cerrado ante cualquier gate ausente.

Estimación: 5 puntos. Dependencias: P2-1, P2-2 y credenciales Apple fuera del
repositorio. Prioridad: alta.

### P2-4 · Matriz real de instalación, actualización y TCC

Como usuario, quiero que una instalación o actualización falle de forma segura
si macOS retira el acceso, para evitar movimientos parciales.

Criterios de aceptación:

- Mac limpio sin Xcode/CLT;
- Apple Silicon e Intel real;
- Downloads, Documents y carpeta seleccionada;
- permiso revocado, volumen desmontado y bookmark obsoleto;
- actualización preserva configuración/journals y vuelve a dry-run;
- app y agente se comprueban por separado.

Estimación: 5 puntos. Dependencias: P2-2 y P2-3. Prioridad: alta.

### P2-5 · Primera GitHub Release para usuarios

Como receptor, quiero una descarga y unas instrucciones breves, para instalar y
verificar la versión correcta sin compilar.

Criterios de aceptación:

- release contiene DMG, checksum y notas de versión;
- README deja de presentar la compilación como método normal;
- rollback y desinstalación están documentados;
- ningún gate anterior está pendiente;
- el artefacto publicado se descarga y revalida desde cero.

Estimación: 3 puntos. Dependencias: P2-1 a P2-4. Prioridad: alta.

## Orden de ejecución

1. P2-1, identidad pública.
2. Prototipo mínimo de P2-2 conforme a ADR-0001.
3. P2-3, distribución firmada/notarizada.
4. P2-4, matriz en hardware real.
5. P2-5, publicación únicamente con todos los gates verdes.

La fase 2 se considera iniciada con este backlog y ADR aprobados. No se considera
terminada hasta publicar y revalidar el primer DMG Developer ID/notarizado.
