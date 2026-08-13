# ADR-0001: Arquitectura nativa para la futura aplicación macOS

- Estado: Aceptado como dirección; implementación condicionada a prototipos
- Fecha: 2026-08-12
- Decisores: propietario del proyecto y Codex
- Alcance: evolución posterior a TidyDrop 1.0.2

## Contexto

TidyDrop 1.0.2 es una utilidad local de Swift/Foundation con CLI y un LaunchAgent periódico. Esta versión prioriza seguridad, auditabilidad y compatibilidad con Apple Command Line Tools; no necesita Xcode completo y permanece separada de la futura interfaz gráfica.

La siguiente etapa pretende convertir el producto en una aplicación macOS profesional sin perder estas propiedades:

- procesamiento completamente local y sin telemetría;
- consumo mínimo cuando no hay cambios;
- acceso limitado a una carpeta elegida por el usuario;
- decisiones explicables, journal previo al movimiento y undo conservador;
- integración nativa con macOS, accesibilidad y teclado;
- distribución para Apple Silicon e Intel mientras ambas arquitecturas sigan dentro del soporte del producto.

## Decisión

La futura aplicación seguirá una arquitectura nativa compuesta por tres partes.

### Aplicación principal

- Swift en modo de concurrencia estricta, adoptado por etapas.
- Interfaz AppKit-first mediante ventanas, toolbars, split views, tablas, menús e inspectores nativos.
- SwiftUI solo para componentes aislados donde reduzca complejidad sin definir por sí solo la identidad visual.
- `NSOpenPanel` para elegir la carpeta activa.
- Editor de reglas, actividad, historial y configuración; la aplicación no vigila archivos cuando está cerrada.

### Agente mínimo

- Swift/Foundation, sin AppKit, SwiftUI, WebKit, red, thumbnails ni indexación de contenido.
- Incluido dentro del bundle y registrado con `SMAppService`, sujeto a consentimiento del usuario.
- FSEvents para recibir señales de cambio y agrupar ráfagas.
- Un único temporizador con tolerancia para las sondas de estabilidad pendientes; ninguno cuando no hay candidatos.
- QoS de utilidad o background para trabajo automático.
- Respeto de Low Power Mode y estado térmico para posponer mantenimiento no esencial.

FSEvents no será la fuente de verdad. El agente reconciliará la carpeta activa al arrancar, después de sleep/wake, al remontar un volumen, al cambiar la raíz vigilada y cuando aparezcan eventos descartados o que obliguen a reexaminar el árbol. Una notificación nunca bastará por sí sola para autorizar un movimiento.

### Núcleo y datos

- Motor compartido de Swift puro + Foundation + POSIX/Darwin.
- Snapshots críticos mediante `lstat(2)` fresco, precisión de nanosegundos, rechazo de symlinks y comprobación de dispositivo/inode.
- `UniformTypeIdentifiers.UTType` para clasificación antes de considerar lectura limitada de cabeceras.
- Manifiestos transaccionales durables como fuente canónica de apply, recuperación y undo.
- SQLite local opcional para reglas, historial consultable e índices derivados, con el agente como único escritor. SQLite no sustituirá el journal transaccional hasta que una prueba de crash recovery demuestre garantías equivalentes o superiores.
- Comunicación entre app y agente mediante XPC, con autenticación mutua basada en requisitos de firma cuando la API y el mínimo de macOS seleccionado lo permitan.

### Seguridad y distribución

- App Sandbox para la app y sus componentes compatibles.
- Acceso de lectura/escritura a la carpeta seleccionada mediante security-scoped bookmarks, con renovación de bookmarks obsoletos y ciclos correctos de `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()`.
- App Group solo si el prototipo demuestra que app y agente necesitan almacenamiento compartido; no se añadirá preventivamente.
- Entitlements mínimos, Hardened Runtime, firma Developer ID y notarización para distribución directa.
- La compatibilidad con Mac App Store se evaluará como gate separado; App Sandbox es obligatorio para ese canal, pero no garantiza por sí solo la aceptación.
- Binarios Universal 2 (`arm64` + `x86_64`) para app, agente y componentes mientras Intel permanezca soportado.
- macOS 13 Ventura como mínimo arquitectónico inicial por `SMAppService`; se reevaluará al comenzar la implementación según el soporte vigente de Apple y la matriz real de usuarios.

## Gates antes de construir

Esta decisión no autoriza una reescritura inmediata. Antes de sustituir TidyDrop 1.0.2 deben pasar prototipos pequeños y verificables:

1. Registrar, aprobar, actualizar y retirar el agente incluido mediante `SMAppService`.
2. Demostrar que el agente sandboxed recupera y usa de forma persistente el bookmark de una carpeta elegida, incluidos volumen externo, desmontaje y bookmark obsoleto.
3. Verificar XPC app-agente y rechazo de clientes que no satisfagan el requisito de firma.
4. Simular eventos FSEvents perdidos y demostrar reconciliación completa sin movimientos duplicados.
5. Demostrar crash recovery entre journal, rename, SQLite y actualización de UI.
6. Medir energía, wakeups, CPU, memoria e I/O con Instruments en Apple Silicon e Intel.
7. Validar accesibilidad, navegación por teclado y estados dry-run/apply/undo en wireframes y prototipo aprobados.
8. Elegir explícitamente el canal de distribución y preparar Developer ID, notarización y, si procede, requisitos de Mac App Store.

Hasta que todos los gates estén verdes, la implementación 1.0.2 sigue siendo la referencia funcional y de seguridad.

## Entorno de desarrollo

No se instalará Xcode como parte de esta decisión ni de la publicación inicial en GitHub. TidyDrop 1.0.2 continúa compilando con Apple Command Line Tools.

La aplicación profesional sí requerirá un entorno de desarrollo controlado con Xcode para proyectos AppKit, entitlements, Universal 2, firma, notarización, XCTest o Swift Testing e Instruments. Puede ser este Mac tras una autorización futura o una máquina de build separada. Los usuarios finales nunca necesitarán Xcode.

## Experiencia e identidad visual

La UI será un banco de trabajo, no un dashboard. La estructura base será navegación, tabla central e inspector contextual. La identidad “Drop Path” mostrará de forma compacta:

```text
Origen  ───── Regla ───── Destino
```

Antes de implementar la interfaz deberán aprobarse mapa de información, wireframes, prototipo navegable, tipografía/espaciado, estados de error y permisos, comportamiento de teclado y ventanas, y representación inequívoca de dry-run, apply y undo.

No se usarán Electron, React Native, Flutter o Catalyst. Tampoco se añadirá una interfaz SwiftUI genérica basada en cards, grandes métricas o decoración sin función.

## Consecuencias

### Ventajas

- Menos wakeups y escaneos vacíos que el polling periódico.
- Integración directa con convenciones, accesibilidad y comportamiento de escritorio de macOS.
- Menor superficie de ataque al separar UI y agente y limitar acceso mediante Sandbox.
- Binarios nativos para Apple Silicon e Intel.
- Reglas, actividad y undo explicables sin mantener abierta la aplicación.

### Costes y riesgos

- Xcode, Apple Developer Program, firma, notarización y pruebas en hardware real pasan a ser parte del desarrollo profesional.
- FSEvents introduce estados de recuperación y reconciliación que deben probarse; no elimina la necesidad de enumerar el árbol en circunstancias concretas.
- Security-scoped bookmarks, Sandbox, `SMAppService` y XPC entre procesos requieren un prototipo integrado antes de fijar el diseño final.
- Universal 2 duplica trabajo de build y amplía la matriz de pruebas.
- Continúa existiendo una ventana TOCTOU residual entre el último snapshot y el rename.

## Alternativas descartadas

- Mantener polling cada cinco minutos como arquitectura final: válido para 1.0.2, pero genera wakeups y ofrece peor inmediatez.
- SwiftUI-first: útil en partes aisladas, pero ofrece menos control para la herramienta de escritorio densa prevista.
- Electron, Flutter, React Native o Catalyst: añaden runtime o abstracción sin una necesidad multiplataforma.
- SQLite como único journal desde el primer día: aumenta el riesgo de perder garantías ya demostradas de recuperación y undo.
- Instalar directamente un plist de LaunchAgent desde scripts en la app final: se prefiere el flujo incluido y consentido de Service Management.

## Privacidad del repositorio

El repositorio público contiene código fuente, documentación, ejemplos y evidencia técnica sanitizada. No debe incluir configuración instalada, logs reales, estado, nombres de archivos del usuario, bookmarks, credenciales, certificados, tokens ni contenido de la carpeta activa. GitHub Secret Scanning, Push Protection, Dependabot y el reporte privado de vulnerabilidades permanecen habilitados.

## Referencias

- [Service Management y SMAppService](https://developer.apple.com/documentation/servicemanagement/)
- [Registro de un servicio con aprobación del usuario](https://developer.apple.com/documentation/servicemanagement/smappservice/register())
- [File System Events](https://developer.apple.com/documentation/coreservices/file_system_events)
- [Eventos FSEvents descartados](https://developer.apple.com/documentation/coreservices/kfseventstreameventflaguserdropped)
- [Acceso a archivos desde App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [Protección de datos con App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)
- [Requisito de firma para NSXPCConnection](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:))
- [Construcción de un binario universal para macOS](https://developer.apple.com/documentation/apple-silicon/building-a-universal-macos-binary)
