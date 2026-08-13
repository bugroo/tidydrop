# Validación de TidyDrop 1.1.0 (candidato)

La validación se ejecuta con Apple Command Line Tools, sin Xcode completo ni XCTest, y trata advertencias como errores.

Gates obligatorios:

1. `scripts/doctor.sh` y regresiones de SDK.
2. Build debug y release.
3. Build Universal 2 y pipeline de distribución fail-closed en `/private/tmp`.
4. Self-tests propios: 64, incluidas las fronteras balanceadas de auditoría
   programada y el runner del agente aislado, sin reducir las regresiones
   anteriores.
5. Veinte repeticiones de las carreras de estabilidad.
6. Selector AppKit real abierto y cancelado automáticamente por un seam de prueba, con checksum de configuración invariable.
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

Ninguna prueba apply o undo usa una carpeta personal. Los artefactos de evidencia se guardan en `docs/evidence` y el informe externo de distribución resume comandos, códigos de salida y resultados observados.

El DMG de desarrollo verifica estructura y portabilidad, pero no sustituye los
gates Developer ID, notarización, `stapler`, Gatekeeper, Intel real y Mac limpio.
No se publica como Release para usuarios finales.
