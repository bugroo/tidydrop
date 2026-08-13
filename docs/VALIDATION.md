# Validación de TidyDrop 1.0.2

La validación se ejecuta con Apple Command Line Tools, sin Xcode completo ni XCTest, y trata advertencias como errores.

Gates obligatorios:

1. `scripts/doctor.sh` y regresiones de SDK.
2. Build debug y release.
3. Build Universal 2 y pipeline de distribución fail-closed en `/private/tmp`.
4. Self-tests propios: 62, incluidas las fronteras balanceadas de auditoría programada, sin reducir las 52 regresiones anteriores.
5. Veinte repeticiones de las carreras de estabilidad.
6. Selector AppKit real abierto y cancelado automáticamente por un seam de prueba, con checksum de configuración invariable.
7. Integración CLI temporal: dry-run, apply, colisiones, undo, carpeta activa y `source_unavailable`.
8. Renderizado del LaunchAgent y plist.
9. Desinstalador en HOME temporal.
10. Auditoría estática de red, dependencias, XCTest, `sudo`, borrado y stdout/stderr.
11. Demo dry-run temporal.
12. Distribución extraída y revalidada desde cero.
13. Regresiones de rename exclusivo, colisión tardía, sustitución de categoría por symlink, lock/JSON sin seguimiento, timeout MIME y reutilización silenciosa del dry-run.
14. Build adicional en modo de lenguaje Swift 6 estricto.

Ninguna prueba apply o undo usa una carpeta personal. Los artefactos de evidencia se guardan en `docs/evidence` y el informe externo de distribución resume comandos, códigos de salida y resultados observados.
