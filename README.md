# TidyDrop 1.0.2

<p align="center">
  <img src="docs/assets/tidydrop-hero.png" alt="TidyDrop organiza archivos localmente mediante una ruta clara y reversible" width="100%">
</p>

**Organización local, decisiones transparentes y reversión conservadora para macOS.**

TidyDrop organiza localmente el primer nivel de una carpeta elegida en subcarpetas por categoría. No sube contenido, no usa red, telemetría, servicios cloud ni dependencias externas.

Las decisiones duraderas de arquitectura, distribución, permisos y actualizaciones se conservan en el [registro de ADR](docs/adr/README.md). La aplicación macOS futura está definida en [ADR-0001](docs/adr/0001-native-macos-application-architecture.md) y la distribución firmada, las actualizaciones y la continuidad TCC en [ADR-0002](docs/adr/0002-distribution-updates-and-tcc-continuity.md).

La [fase 1 de distribución](docs/RELEASE-PHASE-1.md) ya contiene build Universal 2, gates de Hardened Runtime, notarización fail-closed y CI sin secretos. Sigue siendo preparación técnica: no existe todavía una release Developer ID/notarizada apta para entregar a un amigo.

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

Las decisiones críticas usan un `lstat(2)` nuevo en cada lectura. El snapshot conserva tipo, tamaño, `st_dev`, `st_ino`, mtime con segundos y nanosegundos y, en macOS, birth time y el flag oculto. No se usan metadatos Foundation para tamaño, tiempos, identidad, tipo ni estado oculto.

El motor lee el archivo durante la enumeración, antes de esperar, después de esperar y otra vez inmediatamente antes del `rename`. Los cambios producen `changed_before_probe`, `changed_during_probe` o `changed_before_move`; el archivo queda en origen y se actualiza su observación de estabilidad.

Apply y undo abren los directorios sin seguir symlinks, vuelven a comprobar el origen mediante `fstatat(2)` y usan `renameatx_np(..., RENAME_EXCL)` en macOS. Esto impide sobrescribir una colisión creada en el último instante y bloquea el intercambio del directorio de categoría por un symlink. Sigue existiendo una ventana TOCTOU residual para que el proceso escritor cambie el mismo archivo entre el último snapshot y el rename; no puede eliminarse universalmente sin coordinación con ese escritor.

## Carpetas importantes

TidyDrop 1.0.2 mantiene **una sola carpeta activa**. No vigila simultáneamente todas estas ubicaciones:

- `~/Downloads`: predeterminada y compatible.
- `/Users/rootml`: rechazada deliberadamente por ser el home completo y abarcar datos y rutas internas.
- `~/Documents`: seleccionable si TCC permite acceso; cambiarla vuelve a dry-run.
- iCloud Drive: su carpeta local puede validarse, pero el acceso del LaunchAgent debe comprobarse después y los archivos no descargados (`.icloud`) se ignoran.
- Google Drive: la raíz del proveedor puede ser de solo lectura y rechazarse; una subcarpeta local escribible puede seleccionarse. Los conflictos y la sincronización del proveedor quedan fuera del control de TidyDrop.

Para ubicaciones cloud, empieza siempre en dry-run. La validación de ruta no equivale a una garantía sobre TCC, disponibilidad offline o semántica de sincronización.

## Privacidad y permisos TCC

El bundle explica acceso a Downloads, Documents, Desktop, volúmenes extraíbles y volúmenes de red. TidyDrop procesa nombres y metadatos localmente y no transmite datos.

La selección mediante `NSOpenPanel` no garantiza por sí sola acceso persistente para `launchd`. El instalador verifica por separado el binario instalado y el LaunchAgent. Si macOS lo requiere, autoriza TidyDrop únicamente en:

```text
System Settings → Privacy & Security → Files & Folders
```

No concedas Full Disk Access. No se modifica TCC automáticamente.

## LaunchAgent y logs

El agente `com.local.tidydrop` ejecuta una pasada breve cada 300 segundos y al iniciar sesión. No queda un daemon propio residente. Las pasadas vacías son silenciosas. Un plan dry-run ya auditado se conserva en una caché privada: mientras su snapshot y configuración no cambien, se omiten la sonda de 750 ms y nuevas líneas de log. `last-scheduled-run.json` se reemplaza para mantener el último estado verificable.

```text
~/Library/Logs/TidyDrop/steward.log
~/Library/Logs/TidyDrop/audit.jsonl
~/Library/Logs/TidyDrop/agent-errors.log
~/Library/Application Support/TidyDrop/state/last-scheduled-run.json
~/Library/Application Support/TidyDrop/state/stability.json
~/Library/Application Support/TidyDrop/state/scheduled-dry-run-cache.json
~/Library/Application Support/TidyDrop/state/transactions/
```

Cada familia de logs conserva el archivo actual y tres copias rotadas, con 5 MiB por archivo por defecto. La retención solo elimina logs rotados y manifiestos terminales propios; nunca elimina contenido de la carpeta activa.

## Clasificación y protección

La clasificación usa primero extensiones —incluidas compuestas—, después patrones de nombre y finalmente MIME mediante `/usr/bin/file`. La sonda MIME no sigue symlinks y tiene un timeout de dos segundos. Ignora directorios, paquetes `.app`, symlinks, ocultos y formatos incompletos como `.crdownload`, `.part`, `.download` y `.aria2`. No sobrescribe: crea sufijos numerados, exige el mismo filesystem y publica el rename con exclusión.

## Configuración

```text
~/Library/Application Support/TidyDrop/config.json
```

La configuración y el estado se leen con tamaño acotado y sin seguir symlinks, y se guardan mediante archivo temporal `0600`, `fsync` y rename atómico. Estado y logs usan directorios `0700`. `require_destination_inside_source` debe permanecer en `true`.

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
./scripts/verify-manifest.sh
./scripts/test-release-pipeline.sh
```

La suite es un ejecutable Swift/Foundation independiente y no importa XCTest.

## Limitaciones reales

- Firma ad hoc: una actualización puede originar una nueva solicitud TCC.
- Una sola carpeta activa en 1.0.2.
- Los volúmenes desmontados producen `source_unavailable` hasta reaparecer.
- Las carpetas cloud dependen de archivos disponibles localmente, permisos TCC y semántica del proveedor.
- El polling de `launchd` sigue despertando una pasada cada 300 segundos; la caché reduce el trabajo, pero la arquitectura FSEvents pertenece a la futura aplicación nativa.
- La ventana TOCTOU del escritor se reduce con snapshots y rename exclusivo, pero no desaparece completamente.

La última medición local de ejecución, recursos y batería está en [Evidencia de ejecución, energía y batería](docs/evidence/runtime-power-audit-2026-08-12.md).
