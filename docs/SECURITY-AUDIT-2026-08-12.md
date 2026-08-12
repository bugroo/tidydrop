# Auditoría de seguridad, robustez y energía — 2026-08-12

## Resumen ejecutivo

La revisión encontró cuatro defectos corregibles y tres limitaciones arquitectónicas conocidas. No se observó red, telemetría, `sudo`, dependencias externas, borrado en la carpeta activa ni activación real. Las correcciones mantienen TidyDrop en dry-run y elevan la suite de 52 a 61 pruebas.

La mejora energética medible está en el dry-run programado: para 13 planes sin cambios, la primera pasada tardó 0,80 s y la segunda 0,03 s, sin crecimiento adicional de `steward.log` ni `audit.jsonl`. La CPU ya era baja; la mejora principal elimina la espera de 750 ms y escrituras repetidas. El despertar periódico cada 300 segundos permanece como limitación de 1.0.2.

## Hallazgos

### TD-AUD-001 — Carrera entre selección de destino y movimiento

- Severidad inicial: alta.
- Estado: corregido.
- Riesgo: una colisión o sustitución de la carpeta de categoría creada después de la comprobación previa podía convertir la garantía “nunca sobrescribir/escapar” en dependiente del comportamiento de `FileManager`.
- Corrección: directorios abiertos con `O_NOFOLLOW`, origen comprobado con `fstatat(2)` respecto al descriptor y publicación mediante `renameatx_np(..., RENAME_EXCL)` en macOS ([FileSystem.swift](../Sources/TidyDropCore/FileSystem.swift)). Apply y undo usan la misma primitiva ([StewardEngine.swift](../Sources/TidyDropCore/StewardEngine.swift)).
- Evidencia: `testExclusiveMoveNeverOverwritesLateCollision`, `testEngineNeverOverwritesCollisionCreatedAtRename` y `testExclusiveMoveRejectsCategoryReplacedBySymlink`.

### TD-AUD-002 — Sustitución por symlink de estado, lock o logs

- Severidad inicial: media.
- Estado: corregido.
- Riesgo: varias operaciones validaban una ruta y luego la abrían mediante Foundation; una sustitución local entre ambos pasos podía seguir un symlink.
- Corrección: `O_NOFOLLOW`/`O_CLOEXEC`, `fstat`, propiedad del usuario, permisos privados, append por descriptor y escritura atómica mediante temporal `0600`, `fsync` y rename ([FileSystem.swift](../Sources/TidyDropCore/FileSystem.swift)).
- Evidencia: `testLockRejectsSymbolicLink`, `testJSONReaderRejectsSymbolicLinkAndOversizedInput`, `testAtomicJSONSaveRejectsSymlinkAndUsesPrivatePermissions` y las pruebas previas de logs.

### TD-AUD-003 — Trabajo y logs repetidos en dry-run sin cambios

- Severidad inicial: media para eficiencia; baja para seguridad.
- Estado: corregido.
- Riesgo: cada ejecución programada volvía a sondear durante 750 ms y registrar los mismos planes, aunque archivo y configuración no hubieran cambiado.
- Corrección: caché privada ligada al snapshot POSIX y a una firma determinista de configuración; solo se consulta en dry-run y nunca autoriza apply. Las observaciones estables dejan de incrementarse indefinidamente ([Stability.swift](../Sources/TidyDropCore/Stability.swift), [StewardEngine.swift](../Sources/TidyDropCore/StewardEngine.swift)).
- Evidencia: `testScheduledDryRunReusesUnchangedPlanWithoutProbeOrLogGrowth`, integración CLI y medición 0,80 s → 0,03 s con logs invariantes.

### TD-AUD-004 — Lecturas y procesos auxiliares sin cota

- Severidad inicial: media.
- Estado: corregido.
- Riesgo: configuración/manifiestos podían cargarse sin límite y `/usr/bin/file` no tenía timeout.
- Corrección: configuración limitada a 4 MiB, manifiestos a 16 MiB, estados a cotas explícitas, cantidades/longitudes máximas de reglas y timeout MIME de dos segundos sin dereferenciar symlinks ([Configuration.swift](../Sources/TidyDropCore/Configuration.swift), [Transactions.swift](../Sources/TidyDropCore/Transactions.swift), [Classifier.swift](../Sources/TidyDropCore/Classifier.swift)).
- Evidencia: `testJSONReaderRejectsSymbolicLinkAndOversizedInput`, `testConfigurationBoundsRuleCountsAndLengths` y `testMIMEDetectorTimesOutBoundedHelper`.

### TD-AUD-005 — Metadatos secundarios Foundation innecesarios

- Severidad inicial: baja.
- Estado: corregido.
- Riesgo: aunque no decidían estabilidad, abrían una segunda ventana de consulta de ruta y reintroducían complejidad de caché.
- Corrección: snapshots e indicador oculto proceden íntegramente de POSIX/Darwin; Foundation queda solo para información no crítica del volumen.
- Evidencia: regresiones de snapshot fresco, nanosegundos, device/inode, symlink y cambio durante sonda.

### TD-AUD-006 — Polling de cinco minutos

- Severidad: informativa.
- Estado: aceptado para 1.0.2.
- Motivo: el LaunchAgent no es residente, usa `ProcessType=Background` y `Nice=10`, no mantiene power assertions y termina tras una pasada. La caché minimiza trabajo, pero `StartInterval=300` aún causa hasta 12 lanzamientos por hora mientras el sistema está despierto.
- Recomendación futura: agente mínimo dirigido por FSEvents, con reconciliación completa ante eventos perdidos. No se introduce en esta auditoría porque cambia arquitectura, TCC, firma y ciclo de vida.

### TD-AUD-007 — Firma ad hoc y ausencia de sandbox/notarización

- Severidad: informativa para instalación local; alta antes de distribución pública.
- Estado: limitación conocida.
- Motivo: la utilidad instalada es arm64, firmada ad hoc, no notarizada y sin App Sandbox. No usa red y opera como el usuario, pero no reúne todavía los controles de una app comercial.
- Recomendación futura: Developer ID, Hardened Runtime, notarización, App Sandbox, bookmarks, SMAppService y componente Universal 2, conforme al ADR de la futura aplicación.

### TD-AUD-008 — Carpetas cloud y amplitud de la fuente

- Severidad: informativa.
- Estado: comportamiento verificado y documentado.
- Resultado local: `~/Downloads`, `~/Documents` e iCloud Drive pasaron validación estructural; `/Users/rootml` fue rechazado; las raíces de Google Drive eran de solo lectura y fueron rechazadas, pero había subcarpetas escribibles que sí validaron.
- Limitación: no se ejecutó apply cloud. TCC del LaunchAgent, archivos offline, conflictos y sincronización deben comprobarse separadamente en dry-run.

### TD-AUD-009 — Regex configurables

- Severidad: baja.
- Estado: riesgo residual aceptado.
- Mitigación: patrones y cantidades están acotados y se aplican únicamente a nombres del primer nivel. La configuración privada pertenece al mismo usuario, que ya puede sustituir el binario. No se ofrece ejecución de scripts ni regex sobre contenido.

## Energía y batería

- Baseline instalado anterior: 0,99 s de pared, 0,02 s de usuario, 0,02 s de sistema y unos 15,5 MiB de RSS máximo en una pasada dry-run con 13 planes.
- Revisión aislada: primera pasada 0,80 s; segunda sin cambios 0,03 s; 0,01 s de usuario y 0,00 s de sistema en la segunda.
- Logs: 3.979/4.659 bytes después de la primera pasada y exactamente los mismos tamaños después de la segunda.
- Power assertions propias: ninguna observada.
- Conclusión: impacto por pasada bajo y notablemente reducido; no se afirma “cero consumo” porque permanecen el lanzamiento periódico, enumeración/lstat y reemplazo del estado programado.

## Alcance de carpetas

TidyDrop 1.0.2 tiene una sola carpeta activa. `Downloads` es el default; Documents, iCloud Drive o una subcarpeta escribible de Google Drive se eligen de una en una. El home completo se rechaza. Elegir una carpeta fuerza dry-run y la validación del LaunchAgent debe repetirse antes de considerar apply.

## Validación e instalación local

- Apple Command Line Tools: Swift 6.3.3 y SDK macOS 26.5; Xcode completo ausente y no requerido.
- Builds: debug, release y compatibilidad estricta Swift 6 con advertencias como errores, todos PASS.
- Self-tests: 61/61 PASS; repetición completa de estabilidad: 20/20 suites PASS.
- Integración: CLI, selector AppKit abrir/cancelar, LaunchAgent, desinstalador, auditoría estática y demo temporal, todos PASS.
- Instalación: `TidyDrop.app` verificada con `codesign --deep --strict`; identificador `com.local.tidydrop`, firma ad hoc, Mach-O arm64.
- LaunchAgent: cargado desde `~/Library/LaunchAgents/com.local.tidydrop.plist`, no residente entre pasadas, programa correcto, `runs=3`, último exit code 0 e intervalo 300 s.
- Última pasada forzada: `20260812T202216.760Z-a7844465`, resultado success, dry-run, 20 entradas escaneadas, 13 planificadas, 0 movidas y 0 errores.
- Pasada sin cambios: `steward.log=116064`, `audit.jsonl=136685` y `stability.json=7414` bytes antes y después; solo se reemplazó el estado acotado de última ejecución.
- Configuración instalada: fuente y destino `~/Downloads`; `apply_enabled=false`.

## Fuentes primarias consultadas

- Apple, [*Energy Efficiency Guide for Mac Apps — Best Practices*](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/BestPractices.html): idle absoluto, minimizar timers, polling e I/O repetido.
- Apple, [*Creating Launch Daemons and Agents*](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html): LaunchAgent por usuario, trabajos periódicos y ciclo de vida.
- Apple, [*Using the File System Events API*](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html): eventos por jerarquía y obligación de reconciliar eventos perdidos.
- Interfaces Darwin del SDK local: `renameatx_np`, `RENAME_EXCL`, `lstat`, `fstatat`, `openat` y `O_NOFOLLOW`.
