# ADR-0002: Distribución, actualizaciones y continuidad de TCC

- Estado: Aceptado; readiness de fase 1 implementada, gates externos pendientes
- Fecha: 2026-08-12
- Decisores: propietario del proyecto y Codex
- Alcance: primera distribución instalable para terceros y sus actualizaciones
- Relacionado: [ADR-0001](0001-native-macos-application-architecture.md)

## Contexto

TidyDrop 1.0.2 funciona localmente con Apple Command Line Tools, una firma ad hoc y un LaunchAgent instalado por script. Es apropiado para desarrollo y validación controlada, pero obliga a cada receptor a compilar y no proporciona la identidad estable que requiere una distribución macOS sin fricción.

macOS protege Downloads, Documents, Desktop, volúmenes de red y volúmenes extraíbles mediante TCC. Una actualización que cambie de identidad de firma, bundle ID, ruta responsable o relación entre app y agente puede provocar una nueva solicitud o pérdida de acceso. Ningún diseño puede prometer que una actualización de macOS conservará siempre una autorización; el producto debe detectar el estado real y fallar cerrado.

## Decisión

### Distribución para terceros

La primera versión compartible sin herramientas de desarrollo se distribuirá directamente, no mediante compilación en el Mac del usuario:

- aplicación precompilada Universal 2 (`arm64` y `x86_64`);
- identificador reverse-DNS estable `io.github.bugroo.tidydrop`, bajo el namespace GitHub controlado por el desarrollador;
- firma `Developer ID Application` con el mismo Team ID para app, agente y componentes;
- Hardened Runtime y entitlements mínimos;
- notarización de Apple y ticket grapado al artefacto;
- DMG o ZIP firmado/notarizado, acompañado de SHA-256 y notas de versión;
- build reproducible mediante un runner macOS controlado, inicialmente GitHub Actions, para no exigir Xcode completo en este Mac;
- ningún requisito de Xcode o Command Line Tools para el usuario final.

La firma ad hoc de 1.0.2 no se presentará como canal de distribución general.

### Actualizaciones

La primera etapa usará actualizaciones manuales descargadas desde Releases. TidyDrop no incorporará todavía un cliente de red ni un auto-updater; añadirlo requiere otro ADR y un threat model de la cadena de actualización.

Cada actualización debe conservar:

- bundle ID y Team ID;
- designated requirement compatible;
- nombres e identificadores del agente y ejecutables responsables;
- jerarquía estable dentro del bundle;
- entitlements compatibles, salvo migración explícitamente probada.

El instalador verificará firma, notarización, versión y compatibilidad antes de reemplazar el bundle. La configuración y los journals se preservan, pero cada instalación o actualización restablece `apply_enabled=false`.

### TCC después de instalar o actualizar

Tras una instalación, actualización de TidyDrop o actualización de macOS:

1. TidyDrop permanece en dry-run.
2. Verifica acceso desde la aplicación/binario responsable.
3. Verifica por separado acceso desde el agente iniciado por macOS.
4. Exige una ejecución nueva con `success`, `dry-run`, `moved=0` y `errors=0`.
5. Si el acceso falla, muestra `source_unavailable` o un error de permiso acotado y no mueve nada.
6. Solo dirige al usuario a **System Settings → Privacy & Security → Files & Folders**.
7. No solicita Full Disk Access, no modifica la base TCC y no ejecuta `tccutil reset`.

Seleccionar una carpeta con `NSOpenPanel` y guardar un security-scoped bookmark son partes necesarias de la futura app sandboxed, pero no se consideran prueba suficiente de que el agente conserva acceso. La verificación del proceso de fondo sigue siendo obligatoria.

### Evolución del agente

La distribución profesional migrará el agente externo de 1.0.2 a un componente incluido y registrado mediante `SMAppService`, conforme a ADR-0001. La migración debe demostrar instalación, consentimiento, actualización, rollback y retirada sin dejar dos agentes activos.

### Re-registro del agente incluido después de una actualización

La auditoría instalada del 14 de agosto de 2026 demostró que reemplazar un
bundle Community Preview firmado ad hoc puede dejar a `launchd` con la versión
anterior del bundle registrada. En el caso observado, el job conservó build 4 y
terminó con `EX_CONFIG` al intentar ejecutar el bundle 1.1.1 build 5.

Por ello, una actualización debe ejecutar el control ServiceManagement desde el
ejecutable principal contenido en el bundle nuevo: desregistrar el LaunchAgent
incluido, registrarlo de nuevo y comprobar su estado. Esta operación se limita
a los servicios propios `io.github.bugroo.tidydrop.agent` y, en el canal ad hoc
build 5, `io.github.bugroo.tidydrop.agent.community.v5`; no usa
`sfltool resetbtm`, no modifica plists del usuario y no toca otros login items.
Apple documenta
`register()` y `unregister()` como la interfaz para LaunchAgents contenidos y
publica un ejemplo de app sin GUI que expone precisamente comandos de registro y
desregistro.

El re-registro no autoriza movimientos. La secuencia obligatoria continúa
siendo: `apply_enabled=false`, re-registro, nueva pasada del agente con
`success`, `dry-run`, `moved=0` y `errors=0`, y solo entonces restauración
explícita del modo anterior. Si el estado es `requiresApproval`, la actualización
se detiene en dry-run y dirige al usuario a Login Items o Files & Folders según
el fallo observado.

Una firma ad hoc no aporta Team ID y su requisito designado queda ligado al
`cdhash`. La actualización instalada de Community Preview build 4 a build 5
confirmó que el mismo label no puede reparar esa identidad: macOS 26 respondió
con `OS_REASON_CODESIGNING / Launch Constraint Violation`. Para esta migración
gratuita concreta, build 5 usa el label versionado
`io.github.bugroo.tidydrop.agent.community.v5` y desregistra el label comunitario
anterior. Las futuras actualizaciones Community deben desregistrar su agente
con el bundle todavía intacto antes de reemplazarlo. El canal Developer ID no
usa labels versionados: conserva `io.github.bugroo.tidydrop.agent`, Team ID y
designated requirement compatibles.

## Gates de release

No se compartirá como aplicación lista para un usuario no técnico hasta demostrar:

1. `codesign --verify --deep --strict` para el bundle final y cada componente.
2. Verificación de requisitos de firma y Team ID esperados.
3. `spctl --assess` y validación de notarización/ticket grapado sin red cuando proceda.
4. Presencia de slices `arm64` y `x86_64`.
5. Instalación limpia sin Xcode ni Command Line Tools en un Mac de prueba.
6. Actualización sobre una versión anterior conservando configuración y journals, pero volviendo a dry-run.
7. Prueba TCC de app y agente en Downloads, Documents y una carpeta seleccionada.
8. Prueba después de una actualización mayor de macOS soportada.
9. Prueba de permiso revocado, volumen desmontado y bookmark obsoleto con fallo cerrado.
10. Artefacto extraído y revalidado mediante checksum y manifiesto interno.

## Consecuencias

### Ventajas

- Un amigo puede instalar sin compilar ni instalar herramientas de desarrollo.
- Gatekeeper reconoce una identidad estable y una notarización verificable.
- Mantener identidad y firma reduce solicitudes TCC evitables entre versiones.
- El fail-closed en dry-run evita que un cambio de permisos se convierta en movimientos parciales.
- La ausencia inicial de auto-update conserva el runtime sin red y reduce superficie de supply chain.

### Costes y límites

- Requiere Apple Developer Program, certificados, notarización y un entorno Xcode controlado de CI/build.
- Apple puede volver a solicitar consentimiento tras cambios relevantes de binario, identidad o sistema operativo.
- Las pruebas de TCC necesitan Macs reales; no se sustituyen completamente con CI.
- Las actualizaciones manuales son menos cómodas hasta que se diseñe un mecanismo firmado específico.
- La transición desde `com.local.tidydrop` exigirá una migración única y explícita antes de la primera release general.

## Estado de implementación de fase 1

La fase 1 añade una cadena local y CI fail-closed para:

- compilar slices `arm64` y `x86_64` y ensamblarlos con `lipo`;
- retirar rpaths del toolchain y rechazar dependencias de Xcode/CLT;
- firmar en modo ad hoc de desarrollo o Developer ID de distribución sin mezclar ambos estados;
- exigir Hardened Runtime, timestamp seguro, Team ID y bundle ID esperados;
- enviar con `notarytool --wait`, aceptar únicamente `Accepted` y grapar el ticket;
- extraer y volver a verificar el ZIP final y su SHA-256;
- ejecutar los gates de PR sin secretos, sin permisos de escritura y con acciones fijadas por SHA.

La implementación no resuelve aún los gates externos: Team ID e identidad Developer ID, notarización real, ejecución en Intel, instalación en un Mac limpio y pruebas de continuidad TCC. El bundle ID definitivo queda fijado en `io.github.bugroo.tidydrop`. Ese trabajo continúa en [Fase 2: instalación nativa](../RELEASE-PHASE-2.md), bajo [ADR-0003](0003-end-user-installation-experience.md). El detalle de la cadena ya preparada permanece en [Fase 1 de distribución](../RELEASE-PHASE-1.md).

## Alternativas descartadas

- Seguir enviando el código para compilar con CLT: útil para desarrolladores, no para distribución sin fricción.
- Continuar con firma ad hoc: identidad insuficientemente estable para actualizaciones y TCC de terceros.
- Solicitar Full Disk Access: privilegio demasiado amplio para una sola carpeta elegida.
- Automatizar `tccutil` o escribir la base TCC: no autorizado, frágil y contrario al consentimiento del usuario.
- Añadir un auto-updater ahora: introduce red, firma de feeds y nuevos riesgos antes de cerrar el canal base.
- Mac App Store como primera y única ruta: queda abierta a una evaluación posterior; no elimina la necesidad de prototipar agente, Sandbox y bookmarks.

## Referencias

- [Developer ID](https://developer.apple.com/support/developer-id/)
- [Notarizar software macOS antes de distribuirlo](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Configurar Hardened Runtime](https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime/)
- [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Ejemplo oficial para registrar y desregistrar un LaunchAgent incluido](https://developer.apple.com/documentation/servicemanagement/updating-your-app-package-installer-to-use-the-new-service-management-api)
- [Actualizar helpers de versiones anteriores de macOS](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos)
- [Security-scoped bookmarks](https://developer.apple.com/documentation/professional-video-applications/enabling-security-scoped-bookmark-and-url-access)
- [Control de acceso a archivos y carpetas](https://support.apple.com/guide/mac-help/allow-apps-to-use-your-documents-folder-mchl1ffddf58/mac)
