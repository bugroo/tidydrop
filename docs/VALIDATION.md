# Validación del candidato actual de TidyDrop

La validación se ejecuta con Apple Command Line Tools, sin Xcode completo ni XCTest, y trata advertencias como errores.

Gates obligatorios:

1. `scripts/doctor.sh` y regresiones de SDK.
2. Build debug y release.
3. Build Universal 2 y pipeline de distribución fail-closed en `/private/tmp`.
4. Self-tests propios: 127, incluidas las fronteras balanceadas de auditoría,
   workbench AppKit, canonicalización FSEvents, señal app-agente privada e
   índice SQLite con migración, lectura read-only y rechazo de symlinks,
   sin reducir las regresiones anteriores.
5. Veinte repeticiones filtradas de las tres carreras de estabilidad; el suite
   completo se ejecuta separadamente una vez para no reconstruir y montar DMGs
   sin relación en cada iteración.
6. Contrato del selector AppKit validado sin abrir UI durante gates automáticos;
   la cancelación conserva una regresión propia y el smoke test visual real
   requiere opt-in explícito para no mostrar ventanas durante instalación o CI.
7. Integración CLI temporal: dry-run, apply, colisiones, undo, carpeta activa y `source_unavailable`.
8. Renderizado del LaunchAgent y plist.
9. Desinstalador en HOME temporal.
10. Auditoría estática de red, dependencias, XCTest, `sudo`, borrado y stdout/stderr.
11. Demo dry-run temporal.
12. DMG montado y revalidado desde cero.
13. Regresiones de rename exclusivo, colisión tardía, sustitución de categoría por symlink, lock/JSON sin seguimiento, timeout MIME y reutilización silenciosa del dry-run.
14. Build adicional en modo de lenguaje Swift 6 estricto.
15. El agente incluido no enlaza AppKit, SwiftUI ni WebKit; la interfaz sí enlaza
    AppKit y ServiceManagement.
16. La ruta `distribution` rechaza firma ad hoc, Team ID inválido, falta de
    timestamp y ausencia de credenciales antes de cualquier publicación.
17. La ruta `community` exige su marcador de canal, bundle ID público, firma ad
    hoc y Hardened Runtime, y nunca se acepta como `distribution`.
18. El workflow comunitario está fijado por SHA, no consume secretos Apple,
    genera checksum y atestación, crea un draft, vuelve a descargarlo y publica
    únicamente como prerelease con `latest=false`.
19. El estado del CLI reconoce el agente incluido registrado con `SMAppService`
    y la carpeta activa rechaza tanto el bundle de usuario como el instalado en
    `/Applications` y cualquier raíz que los contenga.
20. La verificación de background exige una pasada reciente de la carpeta activa
    exacta, en el modo esperado y con `agent_ready=true`; registros antiguos sin
    `source_directory` o sin readiness explícito no autorizan movimientos.
21. El bundle declara y contiene un icono `.icns` regular, y la aplicación puede
    iniciarse con una configuración aislada para inspección visual sin tocar el
    estado instalado.
22. La integración FSEvents temporal retrasa artificialmente el watcher y exige
    primero un registro no autorizante `agent_ready=false`, luego otro
    `agent_ready=true` sin abrir la UI; también verifica evento de fuente, ráfaga
    coalescida, señal privada, cero movimientos y reposo.
23. El agente es el único escritor del índice SQLite derivado; la integración
    comprueba que el archivo es regular y privado, mientras la app lo consume
    read-only y un fallo del índice no gobierna apply, recuperación o undo.
24. Los prototipos de seguridad prueban requisitos de firma reales y falsos en
    ambos extremos de XPC, round trip y acceso balanceado de bookmarks, SDK
    macOS 13 en arm64/x86_64 y entitlements mínimos ad hoc sin activarlos en el
    bundle distribuido.
25. El Update Center solo se invoca manualmente, usa un endpoint oficial fijo y
    una sesión efímera acotada, no descarga artefactos y mantiene Core, CLI y
    LaunchAgent sin APIs de red.
26. El bundle Community build 10 contiene el agente actual y los plists de
    migración 9, 8, 7, 6 y 5; el registro anterior se retira antes de registrar el
    nuevo y apply permanece desactivado hasta una verificación fresca.
27. La base de manifiesto Ed25519 verifica formato canónico, firma, canal,
    versión, identidad, fechas, tamaño, hash y macOS mínimo directamente sobre
    un artefacto regular abierto con `O_NOFOLLOW`; una puerta estática confirma
    que sigue offline, sin clave de producción y fuera de targets distribuidos.
28. La base de staging de updates crea un workspace `0700` y artefacto `0600`
    anclados a descriptores, no sigue symlinks, nunca sobrescribe colisiones y
    limpia de forma exacta los parciales en cancelación, exceso y `ENOSPC`
    inyectado. Continúa fuera de todos los targets distribuidos.
29. El transporte autenticado no distribuido construye únicamente la URL
    oficial, usa sesión efímera, limita redirects y autenticación, transmite por
    chunks al staging, rechaza digest incorrecto y limpia tras cancelación o
    HTTP no exitoso. Sus tests usan `URLProtocol` inyectado por SPI y no la red
    real.
30. La inspección autenticada no distribuida vuelve a validar el DMG staged,
    lo verifica y monta read-only en `/private/tmp`, exige layout exacto,
    recorrido físico acotado y sin symlinks internos, identidad/versión
    autenticadas, app/CLI/agente Universal 2 y firma estricta contra requisito.
    La misma ruta vuelve a inspeccionar el DMG Community completo creado por el
    pipeline. Regresiones negativas cubren evidencia falsificada, raíz extra,
    symlink, identidad errónea, binarios thin y manipulación posterior a la firma.
31. La base de recovery no distribuida crea backups privados `0700`/`0600`,
    fuerza dry-run en la copia de configuración, usa el backup online de SQLite,
    verifica schema/integridad/digests y publica el manifiesto al final. Las
    regresiones inyectan tres interrupciones, rechazan symlinks y confirman que
    `/tmp` se resuelve desde descriptor sin debilitar `SQLITE_OPEN_NOFOLLOW`.
32. La retención U5 no distribuida reinspecciona el bundle actual antes y después
    de copiarlo por descriptores, conserva y vuelve a validar su firma Universal
    2, publica hashes completos de bundle/estado y un journal `0600` con
    transición fsync/rename recuperable. Rechaza symlinks, manipulación, replay,
    saltos de estado y reintentos que sobrescribirían una recuperación previa.
33. El helper externo no distribuido y el protocolo de reemplazo están
    restringidos a padres privados `TidyDropIntegration.*` de `/private/tmp`.
    Verifican firma/versión Universal 2, fijan device+inode, usan
    `renameatx_np(RENAME_SWAP)` relativo a descriptores, sincronizan ambos
    directorios y recuperan interrupciones antes y después de install/rollback.
    El gate confirma además que el helper no entra en `TidyDrop.app` ni el DMG.

Ninguna prueba apply o undo usa una carpeta personal. Los artefactos de evidencia se guardan en `docs/evidence` y el informe externo de distribución resume comandos, códigos de salida y resultados observados.

Las auditorías instaladas del 14 de agosto de 2026 están resumidas en
`docs/RUNTIME-AUDIT-2026-08-14.md` y
`docs/RUNTIME-AUDIT-2026-08-14-1.2.0-BUILD8.md`, más las actualizaciones a build
9 y 10 en `docs/RUNTIME-AUDIT-2026-08-14-1.3.0-BUILD9.md` y
`docs/RUNTIME-AUDIT-2026-08-14-1.3.0-BUILD10.md`. Verifican agentes FSEvents,
dry-run, migración y reposo, y registran el hallazgo de orden de arranque de
build 9. Conservan únicamente métricas y conteos; no publican nombres de archivos
personales.

El DMG de desarrollo verifica estructura y portabilidad y no se publica. El DMG
Community Preview añade procedencia y una instalación explícitamente no
notarizada; tampoco sustituye los gates Developer ID, `stapler`, Gatekeeper sin
excepción, Intel real y Mac limpio exigidos para una release estable.
