# Validación de TidyDrop 1.0.2

La validación se ejecuta con Apple Command Line Tools, sin Xcode completo ni XCTest, y trata advertencias como errores.

Gates obligatorios:

1. `scripts/doctor.sh` y regresiones de SDK.
2. Build debug y release.
3. Self-tests propios, con total superior a 40.
4. Veinte repeticiones de las carreras de estabilidad.
5. Selector AppKit real abierto y cancelado automáticamente por un seam de prueba, con checksum de configuración invariable.
6. Integración CLI temporal: dry-run, apply, colisiones, undo, carpeta activa y `source_unavailable`.
7. Renderizado del LaunchAgent y plist.
8. Desinstalador en HOME temporal.
9. Auditoría estática de red, dependencias, XCTest, `sudo`, borrado y stdout/stderr.
10. Demo dry-run temporal.
11. Distribución extraída y revalidada desde cero.

Ninguna prueba apply o undo usa una carpeta personal. Los artefactos de evidencia se guardan en `docs/evidence` y el informe externo de distribución resume comandos, códigos de salida y resultados observados.
