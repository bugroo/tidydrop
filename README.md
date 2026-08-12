# TidyDrop 1.0.2

TidyDrop organiza localmente el primer nivel de una carpeta elegida en subcarpetas por categoría. No sube contenido, no usa red, telemetría, servicios cloud ni dependencias externas.

## Requisitos

- macOS 13 o posterior en Apple Silicon.
- Apple Command Line Tools con Swift y el SDK de macOS.
- No requiere Xcode completo, XCTest, Homebrew, Python, `pip` ni `sudo`.

La instalación comprueba el SDK explícitamente con `xcrun` antes de compilar Foundation.

## Instalación

```sh
./scripts/install.sh
```

Instala y firma ad hoc:

```text
~/Applications/TidyDrop.app
~/.local/bin/tidydrop
~/Library/Application Support/TidyDrop
~/Library/Logs/TidyDrop
~/Library/LaunchAgents/com.local.tidydrop.plist
```

Cada instalación vuelve obligatoriamente a `apply_enabled=false`. El instalador compila, ejecuta self-tests e integración temporal, carga el LaunchAgent, fuerza una pasada y exige un resultado nuevo y correcto antes de declarar éxito.

## Carpeta activa

TidyDrop 1.0.2 admite una sola carpeta activa. Una instalación nueva usa `~/Downloads` y crea las categorías dentro de ella.

```sh
tidydrop folder show
tidydrop folder choose
tidydrop folder set "/ruta/elegida"
tidydrop folder reset-downloads
tidydrop folder validate
```

`folder choose` abre un `NSOpenPanel` nativo. Cancelar no cambia la configuración. `folder set`, `folder choose` y `folder reset-downloads` establecen `destination_root` igual a la carpeta elegida y vuelven siempre a dry-run; no borran transacciones ni mueven archivos.

Se rechazan `/`, el home del usuario, `~/Library`, symlinks raíz, pseudo-filesystems, rutas inexistentes, rutas sin lectura/escritura y cualquier carpeta que coincida, contenga o esté dentro del bundle, estado o logs de TidyDrop. No existe un bypass inseguro.

Una carpeta de volumen externo o red puede quedar desmontada. En ese caso el agente no la crea, no la interpreta como vacía y no mueve nada: escribe `source_unavailable` en el estado acotado y vuelve a intentarlo en la siguiente pasada.

## Uso seguro

```sh
tidydrop status
tidydrop folder show
tidydrop run --dry-run
tidydrop activate
tidydrop deactivate
tidydrop undo
tidydrop undo --apply
```

- `run` y `run --dry-run` no mueven archivos.
- `activate` habilita apply solo para futuras pasadas programadas.
- `deactivate` restaura dry-run.
- `undo` previsualiza; `undo --apply` restaura la última transacción elegible.
- Las pruebas apply/undo del proyecto se ejecutan exclusivamente en directorios temporales.

## Estabilidad y snapshots POSIX

Las decisiones críticas usan un `lstat(2)` nuevo en cada lectura. El snapshot conserva tipo, tamaño, `st_dev`, `st_ino`, mtime con segundos y nanosegundos y, en macOS, birth time. Foundation solo aporta metadatos secundarios como estado oculto o identificadores adicionales, después de invalidar su caché.

El motor lee el archivo durante la enumeración, antes de esperar, después de esperar y otra vez inmediatamente antes del `rename`. Los cambios producen `changed_before_probe`, `changed_during_probe` o `changed_before_move`; el archivo queda en origen y se actualiza su observación de estabilidad.

Existe una ventana TOCTOU residual entre el último `lstat` y `rename`. No puede eliminarse universalmente sin coordinación o bloqueo del proceso escritor.

## Privacidad y permisos TCC

El bundle explica acceso a Downloads, Documents, Desktop, volúmenes extraíbles y volúmenes de red. TidyDrop procesa nombres y metadatos localmente y no transmite datos.

La selección mediante `NSOpenPanel` no garantiza por sí sola acceso persistente para `launchd`. El instalador verifica por separado el binario instalado y el LaunchAgent. Si macOS lo requiere, autoriza TidyDrop únicamente en:

```text
System Settings → Privacy & Security → Files & Folders
```

No concedas Full Disk Access. No se modifica TCC automáticamente.

## LaunchAgent y logs

El agente `com.local.tidydrop` ejecuta una pasada breve cada 300 segundos y al iniciar sesión. No queda un daemon propio residente. Las pasadas vacías son silenciosas y sobrescriben únicamente `last-scheduled-run.json`.

```text
~/Library/Logs/TidyDrop/steward.log
~/Library/Logs/TidyDrop/audit.jsonl
~/Library/Logs/TidyDrop/agent-errors.log
~/Library/Application Support/TidyDrop/state/last-scheduled-run.json
~/Library/Application Support/TidyDrop/state/stability.json
~/Library/Application Support/TidyDrop/state/transactions/
```

Cada familia de logs conserva el archivo actual y tres copias rotadas, con 5 MiB por archivo por defecto. La retención solo elimina logs rotados y manifiestos terminales propios; nunca elimina contenido de la carpeta activa.

## Clasificación y protección

La clasificación usa primero extensiones —incluidas compuestas—, después patrones de nombre y finalmente MIME mediante `/usr/bin/file`. Ignora directorios, paquetes `.app`, symlinks, ocultos y formatos incompletos como `.crdownload`, `.part`, `.download` y `.aria2`. No sobrescribe: crea sufijos numerados y exige el mismo filesystem para usar `rename`.

## Configuración

```text
~/Library/Application Support/TidyDrop/config.json
```

La configuración se guarda atómicamente con permisos `0600`. Estado y logs usan directorios `0700`. `require_destination_inside_source` debe permanecer en `true`.

## Desinstalación

Conservando configuración, transacciones y logs:

```sh
./scripts/uninstall.sh
```

Eliminación de datos propios:

```sh
./scripts/uninstall.sh --purge
```

El desinstalador descarga exclusivamente `com.local.tidydrop` y no toca archivos organizados, categorías ni una instalación histórica con otro nombre.

## Validación

```sh
./scripts/doctor.sh
swift build -c debug -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
swift run tidydrop-self-test
./scripts/test-doctor.sh
./scripts/test-stability-race.sh
./scripts/test-cli.sh
./scripts/test-launchagent.sh
./scripts/test-uninstall.sh
./scripts/audit-project.sh
./scripts/validate-project.sh
./scripts/demo.sh
```

La suite es un ejecutable Swift/Foundation independiente y no importa XCTest.

## Limitaciones reales

- Firma ad hoc: una actualización puede originar una nueva solicitud TCC.
- Una sola carpeta activa en 1.0.2.
- Los volúmenes desmontados producen `source_unavailable` hasta reaparecer.
- La ventana TOCTOU final se reduce con snapshots POSIX frescos, pero no desaparece completamente.
