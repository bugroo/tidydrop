# Modelo de seguridad de TidyDrop 1.0.2

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

## TCC

El bundle declara las claves de Downloads, Documents, Desktop, volúmenes extraíbles y red. El acceso manual y mediante LaunchAgent se verifica por separado. No se solicita Full Disk Access, no se modifica la base TCC y seleccionar una carpeta no se presenta como garantía de acceso persistente para `launchd`.

## Firma y confianza

La aplicación instalada actual se firma ad hoc localmente. No es Developer ID ni está notarizada. Cambiar el binario puede provocar una nueva decisión TCC. El checksum externo y `MANIFEST.sha256` permiten comprobar la distribución de código fuente.

La cadena de fase 1 separa explícitamente artefactos `development` de `distribution`. Esta última exige Developer ID, Hardened Runtime, timestamp seguro, Team ID, bundle ID definitivo, aceptación de notarización, ticket grapado, Gatekeeper y verificación posterior a la extracción. Ninguna credencial se almacena en el repositorio.

El runtime continúa sin red. La única operación de red nueva pertenece al proceso de release del mantenedor: `notarytool` envía el artefacto firmado al servicio de Apple. No se ejecuta durante instalación, vigilancia, clasificación o undo.

## Fuera de alcance

TidyDrop no intenta defenderse de un usuario local malicioso con la misma cuenta capaz de modificar binarios y configuración. Tampoco puede impedir que un proceso vuelva a abrir y editar un archivo inmediatamente después del movimiento.

La firma ad hoc, la ausencia de App Sandbox/notarización y el polling cada 300 segundos son limitaciones deliberadas de la utilidad 1.0.2. La futura aplicación nativa debe abordarlas con Developer ID, Hardened Runtime, sandbox, bookmarks y un agente FSEvents.
