# Modelo de seguridad de TidyDrop 1.1.2 (candidato)

TidyDrop es local, sin red, telemetría, servicios externos, `sudo` ni dependencias de ejecución. La amenaza principal es el error operativo y el cambio concurrente de archivos por aplicaciones de descarga.

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
cero movimientos y cero errores. La verificación también exige que el registro
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
ni está notarizada. El candidato 1.1.2 conserva explícitamente
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

El runtime continúa sin red. La única operación de red nueva pertenece al proceso de release del mantenedor: `notarytool` envía el artefacto firmado al servicio de Apple. No se ejecuta durante instalación, vigilancia, clasificación o undo.

## Fuera de alcance

TidyDrop no intenta defenderse de un usuario local malicioso con la misma cuenta capaz de modificar binarios y configuración. Tampoco puede impedir que un proceso vuelva a abrir y editar un archivo inmediatamente después del movimiento.

La firma ad hoc de la instalación actual y la ausencia de App Sandbox son
limitaciones deliberadas. La rama 1.2 sustituye el polling del agente incluido
por FSEvents, reconciliación al inicio y un único temporizador cuando existen
archivos aplazados. La integración temporal verifica dry-run, coalescing,
señales privadas de un solo uso y reposo sin nuevas pasadas. Sandbox, bookmarks,
Developer ID y notarización permanecen sujetos a gates separados y no se
declaran resueltos por este prototipo.
