# Modelo de seguridad de TidyDrop 1.0.2

TidyDrop es local, sin red, telemetría, servicios externos, `sudo` ni dependencias de ejecución. La amenaza principal es el error operativo y el cambio concurrente de archivos por aplicaciones de descarga.

## Invariantes

- Dry-run por defecto y después de instalar o cambiar carpeta.
- Una sola carpeta activa, con raíz real, segura, legible y escribible.
- Destino dentro de la fuente y en el mismo filesystem.
- Sin seguimiento de symlinks, recorrido recursivo, sobrescritura ni borrado desde el motor.
- Lock `flock(2)` contra pasadas concurrentes.
- Journal antes de `rename`, reconciliación fail-closed y undo con identidad verificada.
- Retención limitada exclusivamente a logs y manifiestos propios regulares.

## Metadatos frescos

Los atributos críticos proceden de `lstat(2)` nuevo: tipo, tamaño, mtime en nanosegundos, dispositivo e inode; macOS añade birth time. Foundation queda limitada a metadatos secundarios con caché invalidada.

Se compara durante enumeración, antes y después de la sonda y justo antes de mover. Un cambio aplaza el archivo con una razón explícita. Persiste una ventana TOCTOU residual entre el último `lstat` y `rename`; eliminarla exigiría coordinación con el escritor.

## TCC

El bundle declara las claves de Downloads, Documents, Desktop, volúmenes extraíbles y red. El acceso manual y mediante LaunchAgent se verifica por separado. No se solicita Full Disk Access, no se modifica la base TCC y seleccionar una carpeta no se presenta como garantía de acceso persistente para `launchd`.

## Firma y confianza

La aplicación se firma ad hoc localmente. No es Developer ID ni está notarizada. Cambiar el binario puede provocar una nueva decisión TCC. El checksum externo y `MANIFEST.sha256` permiten comprobar la distribución.

## Fuera de alcance

TidyDrop no intenta defenderse de un usuario local malicioso con la misma cuenta capaz de modificar binarios y configuración. Tampoco puede impedir que un proceso vuelva a abrir y editar un archivo inmediatamente después del movimiento.
