# Modelo de seguridad de TidyDrop 1.3.0 Community Preview

TidyDrop procesa archivos localmente, sin telemetría, servicios cloud, `sudo` ni dependencias de ejecución. El agente y el motor de organización permanecen sin red. La única excepción de runtime es el Update Center manual: tras una acción explícita consulta metadatos de releases del repositorio oficial sin enviar nombres, rutas o contenido de archivos.

## Invariantes

- Dry-run por defecto y después de instalar o cambiar carpeta.
- Una sola carpeta activa, con raíz real, segura, legible y escribible.
- Destino dentro de la fuente y en el mismo filesystem.
- Sin seguimiento de symlinks, recorrido recursivo, sobrescritura ni borrado desde el motor.
- Apply y undo usan descriptores de directorio, `fstatat(2)` y rename exclusivo (`RENAME_EXCL`).
- Lock `flock(2)` contra pasadas concurrentes.
- Journal antes de `rename`, reconciliación fail-closed y undo con identidad verificada.
- Retención limitada exclusivamente a logs y manifiestos propios regulares.

## Metadatos frescos

Los atributos críticos proceden de `lstat(2)` nuevo: tipo, tamaño, mtime en nanosegundos, dispositivo e inode; macOS añade birth time y flags. Foundation no decide tipo, tamaño, tiempos, identidad ni estado oculto.

Se compara durante enumeración, antes y después de la sonda y justo antes de mover. El origen vuelve a validarse respecto al descriptor de su directorio y el destino no puede existir al publicar el rename. Un cambio aplaza el archivo con una razón explícita. Persiste una ventana TOCTOU residual para escrituras concurrentes sobre el mismo objeto; eliminarla exigiría coordinación con el escritor.

## Estado y recursos propios

Lock, JSON y logs se abren con `O_NOFOLLOW`, se comprueban mediante descriptor y deben pertenecer al usuario. La escritura JSON usa temporales privados, `fsync` y rename atómico. Configuración, cachés y manifiestos tienen límites de lectura; las reglas tienen cantidades y longitudes máximas. La sonda MIME no sigue symlinks y termina de forma acotada.

La caché de dry-run solo suprime trabajo de previsualización ya auditado. Nunca se consulta en apply y no autoriza movimientos.

El índice `activity.sqlite3` es estado derivado y no autoritativo. Solo la ruta
de ejecución programada escribe; la interfaz abre en modo read-only. Los
manifiestos JSON siguen gobernando apply, recuperación y undo. SQLite se abre
sin seguir symlinks, con esquema no confiable desactivado, límites de tamaño y
retención, permisos `0600` y un padre `0700`. WAL se acepta únicamente si SQLite
confirma el modo, sus sidecars no se eliminan directamente y el índice permanece
en Application Support local aunque la carpeta observada esté en otro volumen.
Un fallo del índice queda acotado al resumen de actividad y no debilita el
journal de archivos.

La validación de carpeta protege tanto `~/Applications/TidyDrop.app` como
`/Applications/TidyDrop.app`; tampoco admite una raíz que contenga cualquiera
de esos bundles. De este modo, la clasificación nunca puede abarcar el código
instalado de TidyDrop.

Una pasada programada con actividad abre y cierra siempre una unidad de auditoría balanceada (`run_started` → eventos → `run_finished`). La supresión solo elimina por completo las pasadas sin acontecimientos; nunca deja un cierre sin su inicio correspondiente.

## TCC

El bundle declara las claves de Downloads, Documents, Desktop, volúmenes extraíbles y red. El acceso manual y mediante LaunchAgent se verifica por separado. No se solicita Full Disk Access, no se modifica la base TCC y seleccionar una carpeta no se presenta como garantía de acceso persistente para `launchd`.

La aplicación nativa registra un agente incluido con `SMAppService`. La rama
1.2 mantiene un agente Foundation/CoreServices residente y bloqueado sobre
FSEvents cuando está inactivo; AppKit y ServiceManagement quedan en el proceso
de interfaz. La activación permanece
bloqueada hasta observar una pasada nueva del agente con `success`, `dry-run`,
cero movimientos, cero errores y `agent_ready=true`. Build 10 escribe primero
un diagnóstico no autorizante con `agent_ready=false`, inicia FSEvents y repite
la reconciliación; así una creación de watcher bloqueada nunca aparenta estar
lista. La verificación también exige que el registro
sea reciente y corresponda a la ruta canónica exacta de la carpeta activa. La
app reanuda esta comprobación al abrirse sin intentar registrar de nuevo un
servicio que macOS ya mantiene habilitado.

La migración desde 1.0.2 valida la procedencia del plist anterior, fuerza
dry-run, descarga el job antiguo y mueve su plist a una copia privada reversible
antes de registrar el agente nuevo. Si el registro falla, restaura el plist y,
si estaba cargado, vuelve a cargar el job anterior. Así se evita que el agente
antiguo reaparezca silenciosamente en el siguiente inicio de sesión.

## Firma y confianza

La aplicación Community Preview se firma ad hoc localmente. No es Developer ID
ni está notarizada. La versión 1.3.0 conserva explícitamente
esa limitación: macOS exige una excepción manual y una actualización puede
provocar nuevas decisiones Gatekeeper o TCC. El DMG se construye desde un tag de
`main`, se publica como prerelease y se acompaña de SHA-256 y GitHub Artifact
Attestation. La atestación prueba procedencia del build, no seguridad ni revisión
de Apple.

Las instrucciones comunitarias no desactivan Gatekeeper, no eliminan cuarentena,
no usan scripts remotos, no solicitan Full Disk Access y mantienen dry-run hasta
verificar una pasada del agente con cero movimientos y errores.

La cadena separa explícitamente `development`, `community` y `distribution`.
`community` exige bundle ID público, canal marcado dentro del Info.plist, firma ad
hoc, Hardened Runtime, Universal 2 y ausencia de una autoridad Apple simulada.
`distribution` exige Developer ID, timestamp seguro, Team ID, notarización,
ticket grapado y Gatekeeper. Ninguna credencial se almacena en el repositorio.

La vigilancia, clasificación, apply y undo continúan sin red. El Update Center usa una sesión efímera, sin cookies ni credenciales, con endpoint, tiempo y tamaño de respuesta acotados. No se ejecuta al iniciar, mediante timer o desde el LaunchAgent; tampoco descarga ni instala artefactos. El proceso de release del mantenedor puede usar `notarytool` para enviar un artefacto firmado a Apple, pero esa operación no forma parte del runtime del usuario.

La selección de releases exige tags y canales estrictos, ignora drafts y downgrades, y construye la URL visible desde el origen oficial en lugar de confiar en enlaces recibidos. GitHub sigue viendo los metadatos normales de una conexión HTTPS cuando el usuario pulsa el botón. [ADR-0013](adr/0013-offline-ed25519-release-manifest-foundation.md) implementa una base aislada para verificar manifiestos Ed25519 y el DMG real sin seguir symlinks, pero no contiene clave de producción ni está conectada a la app distribuida. La firma operativa de releases, instalación staged y rollback permanecen bloqueados por [ADR-0011](adr/0011-manual-update-center-and-recovery-boundary.md) y su [threat model](tidydrop-update-center-threat-model.md).

[ADR-0015](adr/0015-private-update-staging-foundation.md) añade otra base
aislada: un workspace privado y archivo parcial anclados a descriptores POSIX,
con límites autenticados, creación exclusiva, `O_NOFOLLOW`, comprobaciones
`fstat` y finalización `RENAME_EXCL`. Las pruebas cubren cancelación, disco
lleno, tamaño incompleto, symlinks y colisión tardía. No contiene red, montaje,
extracción, instalación ni reemplazo de `/Applications`; esas fronteras siguen
bloqueadas.

[ADR-0017](adr/0017-fixed-origin-authenticated-update-transport.md) conecta esas
bases únicamente desde un módulo de transporte no distribuido y separado del
verificador offline: deriva la URL desde el
manifiesto autenticado, limita redirects al origen de assets de GitHub, usa una
sesión efímera sin cookies, caché o credenciales y transmite por chunks al
staging privado. El SHA-256 autenticado se comprueba antes de finalizar el
artefacto. Los tests inyectan el protocolo dentro de la sesión y no pueden caer
accidentalmente a la red real. La app, CLI, Core y LaunchAgent no importan esta
ruta; extracción, instalación y rollback continúan bloqueados.

[ADR-0018](adr/0018-safe-authenticated-dmg-bundle-inspection.md) completa la
base técnica U4 sin distribuirla: vuelve a comprobar identidad y SHA-256 del
staging, verifica y monta el DMG read-only dentro del workspace privado, limita
el árbol físico y rechaza symlinks dentro de la app. Exige identidad y versión
autenticadas, binarios `arm64` + `x86_64` para app, CLI y agente, y valida firma
estricta/nested/all-architectures contra un requisito explícito. La regresión
real usa exclusivamente `/private/tmp` y desmonta el DMG. El módulo no copia,
instala, registra, abre o reemplaza aplicaciones; U5, la clave pública de
producción y Developer ID siguen siendo gates obligatorios.

[ADR-0019](adr/0019-private-recovery-state-snapshot.md) inicia U5 sin conceder
autoridad de reemplazo: crea un workspace privado, copia la configuración con
`apply_enabled=false`, realiza un backup online consistente del SQLite y valida
schema, integridad y hashes antes de escribir el manifiesto final. Las rutas
SQLite se resuelven desde descriptores y vuelven a comprobar device/inode para
que la canonicalización `/private/tmp` → `/tmp` de macOS no debilite
`SQLITE_OPEN_NOFOLLOW`. Tres fallos inyectados limpian solo el workspace exacto.
La app instalada, el agente y las carpetas personales no participan; retención
del bundle anterior, recovery externo y reemplazo atómico continúan bloqueados.

[ADR-0020](adr/0020-retained-current-bundle-and-recovery-journal.md) añade la
retención del bundle actual sin distribuir autoridad de instalación. El mismo
inspector comprueba identidad, versión, Universal 2 y firma antes de la copia,
vuelve a validar la fuente, inspecciona la copia y registra un hash determinista
del árbol completo. La copia usa descriptores, `O_NOFOLLOW`, creación exclusiva
y `fcopyfile`; no acepta symlinks, hardlinks ni entradas especiales. Un journal
privado fuerza dry-run, usa transiciones permitidas y recupera una única
publicación `.next` duradera mediante `fsync`/`rename`. No reemplaza, abre,
registra ni ejecuta aplicaciones; el helper externo y el rollback real siguen
bloqueados.

## Fuera de alcance

TidyDrop no intenta defenderse de un usuario local malicioso con la misma cuenta capaz de modificar binarios y configuración. Tampoco puede impedir que un proceso vuelva a abrir y editar un archivo inmediatamente después del movimiento.

La firma ad hoc de la instalación actual y la ausencia de App Sandbox son
limitaciones deliberadas. La rama 1.3 conserva el agente FSEvents introducido en
1.2, con reconciliación al inicio y un único temporizador cuando existen
archivos aplazados. La integración temporal verifica dry-run, coalescing,
señales privadas de un solo uso y reposo sin nuevas pasadas. Sandbox, bookmarks,
Developer ID y notarización permanecen sujetos a gates separados y no se
declaran resueltos por este prototipo.

La rama 1.3 contiene además prototipos verificables de requisitos designados de
firma, rechazo de un peer XPC con identidad imposible, bookmarks con scope y
entitlements mínimos sin red. Estos controles todavía no están habilitados en
el bundle Community: una firma ad hoc no ofrece continuidad de identidad y un
round trip de bookmark no demuestra acceso persistente del LaunchAgent
sandboxed. ADR-0009 mantiene ese rollout bloqueado hasta probar el servicio
Mach real, relanzamiento, stale bookmark y volúmenes externos con Developer ID.
