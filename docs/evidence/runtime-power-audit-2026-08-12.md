# Evidencia de ejecución, energía y batería — 2026-08-12

Medición local del TidyDrop 1.0.2 instalado. Todas las ejecuciones fueron `dry-run`; no se ejecutó `activate`, `run --apply` ni `undo --apply`.

## Entorno

```text
macOS: 26.5.2 (25F84)
arquitectura: arm64
developer directory: /Library/Developer/CommandLineTools
Swift: 6.3.3
Xcode completo: no usado
```

## Estado instalado

```text
versión: 1.0.2
fuente: ~/Downloads
destino: ~/Downloads
apply_enabled: false
intervalo: 300 segundos
LaunchAgent: com.local.tidydrop
programa: ~/Applications/TidyDrop.app/Contents/MacOS/tidydrop
estado entre pasadas: not running
ejecuciones observadas antes de la prueba forzada: 18
último código de salida: 0
```

## Dos pasadas directas sin cambios

```text
pasada 1: real 0.09 s; user 0.01 s; sys 0.01 s; RSS máximo 15,056,896 bytes
pasada 2: real 0.03 s; user 0.00 s; sys 0.00 s; RSS máximo 15,073,280 bytes
swaps: 0
block input operations: 0
block output operations: 0
proceso TidyDrop después de terminar: ninguno
audit.jsonl: 136,685 → 136,685 bytes
steward.log: 116,064 → 116,064 bytes
```

## Pasada real del LaunchAgent

```text
run_id anterior: 20260812T214058.520Z-6994d397
run_id nuevo: 20260812T214123.204Z-6b19fcaf
timestamp UTC: 2026-08-12T21:41:23Z
outcome: success
mode: dry-run
scanned: 20
planned: 13
moved: 0
errors: 0
audit.jsonl delta: 0 bytes
steward.log delta: 0 bytes
LaunchAgent después de terminar: not running
ejecuciones acumuladas: 19
último código de salida: 0
```

## Batería y power assertions

```text
alimentación durante la medición: AC Power
condición: Normal
Low Power Mode: No
power assertions propiedad de TidyDrop: ninguna
```

Las métricas específicas del dispositivo se omiten de esta evidencia pública. El sistema sí tenía aserciones ajenas a TidyDrop que impedían reposo. Si se mantienen al usar batería pueden aumentar el consumo, pero no fueron creadas por TidyDrop.

## Incidencia de aislamiento y restauración

La validación integral descubrió que el test temporal del desinstalador descargaba la etiqueta real de `launchd`: cambiar `HOME` no aísla el dominio GUI. No eliminó ningún componente ni dato y no activó movimientos. El test fue corregido para inyectar un stub de `launchctl` y verificar sus argumentos.

Después de la corrección se volvió a cargar el plist instalado y `verify-install.sh` confirmó:

```text
bundle y plists: OK
LaunchAgent: loaded; not running entre pasadas
programa: ~/Applications/TidyDrop.app/Contents/MacOS/tidydrop
último código de salida: 0
apply_enabled: false
outcome: success
mode: dry-run
moved: 0
errors: 0
```

## Conclusión acotada

TidyDrop está haciendo su trabajo en modo de observación: enumera el primer nivel, conserva 13 decisiones planificadas, verifica estabilidad y no mueve archivos. La caché deja las pasadas repetidas en unas centésimas de segundo y sin crecimiento de logs. No hay proceso residente ni aserción de energía propia.

El impacto no es literalmente cero: `StartInterval=300` produce hasta 12 lanzamientos por hora mientras macOS los programe y cada pasada reemplaza un pequeño estado acotado. Esta medición puntual no puede demostrar degradación histórica de batería; sí descarta, durante la prueba, CPU sostenida, memoria residente, swapping, logs crecientes o bloqueo del reposo atribuibles a TidyDrop.
