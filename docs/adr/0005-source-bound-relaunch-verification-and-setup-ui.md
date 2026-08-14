# ADR-0005: Verificación al reabrir vinculada a la carpeta y UI de configuración

- Estado: Aceptado e implementado en 1.1.2
- Fecha: 2026-08-14
- Decisores: propietario del proyecto y Codex
- Relacionado: [ADR-0001](0001-native-macos-application-architecture.md), [ADR-0002](0002-distribution-updates-and-tcc-continuity.md) y [ADR-0004](0004-community-preview-without-developer-id.md)

## Contexto

La app 1.1.1 inicializaba la verificación del agente como falsa cada vez que se
abría. Solo iniciaba una nueva comprobación dentro de la acción que registraba
el agente. Si macOS ya lo tenía registrado, la UI quedaba en «verification
pending» e invitaba a repetir un registro que no era necesario. Además, el
registro de la última pasada no indicaba qué carpeta había comprobado.

La pantalla inicial mostraba cinco acciones simultáneas y términos internos
como «Register Background Agent». No presentaba el último resultado programado
ni un progreso claro de los tres pasos necesarios para organizar archivos.

## Decisión

1. Cada pasada programada guarda la ruta canónica de su carpeta fuente en
   `source_directory`.
2. Una pasada solo verifica background si es reciente, terminó correctamente,
   corresponde a la carpeta activa exacta y coincide con el modo configurado.
   En dry-run también debe declarar cero movimientos.
3. Los registros 1.1.1 siguen decodificando, pero al no contener la carpeta no
   autorizan apply. Se exige una nueva pasada segura.
4. Al abrir la app, un agente ya habilitado se comprueba automáticamente. Si el
   modo es dry-run y falta evidencia reciente, la app solicita una pasada con
   `launchctl kickstart` sin volver a registrarlo.
5. Si apply ya estaba habilitado, la app no fuerza una ejecución adicional al
   abrirse; espera la siguiente pasada programada. Pausar apply sí permite una
   comprobación dry-run inmediata.
6. La UI AppKit usa una ventana redimensionable, `NSPathControl`, último estado,
   pasos de configuración, progreso no modal, dos acciones de exploración y dos
   controles contextuales. Los nombres visibles describen la intención del
   usuario, no la implementación de ServiceManagement.
7. El canal Community build 6 usa un label versionado nuevo. El bundle conserva
   el plist build 5 solo para desregistrarlo de forma controlada durante la
   actualización ad hoc.

## Seguridad y energía

La comprobación iniciada por la UI solo fuerza dry-run. Nunca usa `-k`, nunca
activa apply y nunca acepta una pasada de otra carpeta. El temporizador de UI se
invalida al verificar, al agotar el plazo o al cerrar la app; no cambia el agente
de una pasada corta cada 300 segundos ni añade trabajo residente al runtime.

## Consecuencias

- Reabrir TidyDrop refleja el estado real sin un registro duplicado.
- Cambiar de carpeta exige evidencia nueva y continúa forzando dry-run.
- Una actualización comunitaria ad hoc vuelve a necesitar migración de label;
  Developer ID sigue siendo la solución estable prevista por ADR-0002.
- El historial de actividad, las reglas editables y FSEvents permanecen fuera de
  1.1.2 y siguen sujetos al prototipo AppKit-first de ADR-0001.
