# ADR-0003: Experiencia de instalación para usuarios finales

- Estado: Aceptado; implementación pendiente
- Fecha: 2026-08-13
- Decisores: propietario del proyecto y Codex
- Alcance: instalación inicial y actualizaciones manuales de TidyDrop para usuarios no técnicos
- Relacionado: [ADR-0001](0001-native-macos-application-architecture.md) y [ADR-0002](0002-distribution-updates-and-tcc-continuity.md)

## Contexto

TidyDrop 1.0.2 se instala actualmente desde código fuente mediante
`scripts/install.sh`. Ese canal es auditable y apropiado para desarrollo, pero
requiere Terminal y Apple Command Line Tools. Un comando remoto del tipo
`curl ... | sh` ocultaría parte de la operación y ejecutaría código descargado
directamente, sin resolver la identidad de la aplicación, Gatekeeper,
notarización, TCC ni una experiencia comprensible de consentimiento.

El producto final debe poder instalarse sin Bash, PowerShell, Xcode, Command
Line Tools, Homebrew ni privilegios de administrador.

## Decisión

### Canal para usuarios finales

La instalación pública recomendada será un DMG firmado y notarizado que
contenga `TidyDrop.app`. El usuario abrirá el DMG, copiará la aplicación a
Applications y completará dentro de la propia app una incorporación breve:

1. explicación local de privacidad y alcance;
2. selección o confirmación de una única carpeta;
3. registro del agente incluido mediante `SMAppService`;
4. comprobación separada del acceso de la app y del agente;
5. primera pasada obligatoria en dry-run;
6. activación explícita de movimientos por el usuario.

No se publicará `curl | sh` como método de instalación recomendado. El script
local se conserva para desarrollo, auditoría y recuperación controlada, pero no
será la interfaz normal de un receptor.

### Actualizaciones

La primera etapa seguirá usando descargas manuales desde GitHub Releases. Una
actualización conservará configuración y journals, pero volverá a dry-run y
repetirá la comprobación de TCC antes de ofrecer la reactivación. Un actualizador
automático requerirá otro ADR y un threat model específico.

### Transición desde 1.0.2

La app profesional no coexistirá silenciosamente con el LaunchAgent externo
`com.local.tidydrop`. La migración debe detectar la instalación anterior,
preservar datos, impedir dos agentes activos y ofrecer rollback verificable. No
eliminará una instalación antigua sin identificar primero su procedencia y sin
una acción explícita del usuario.

## Gates

No se presentará el DMG como instalación pública terminada hasta demostrar:

1. identidad definitiva de bundle y Team ID estable;
2. app y agente Universal 2 con firma Developer ID y Hardened Runtime;
3. notarización aceptada y ticket grapado;
4. Gatekeeper aprobado desde el DMG descargado;
5. instalación inicial sin herramientas de desarrollo ni Terminal;
6. incorporación, cancelación y recuperación accesibles por teclado;
7. app y agente verificados por separado ante TCC;
8. actualización que preserve datos y vuelva a dry-run;
9. migración sin dos agentes activos;
10. prueba real en Apple Silicon, Intel y un Mac limpio soportado.

## Consecuencias

### Ventajas

- La instalación normal se parece a la de una aplicación macOS, no a la de una
  herramienta para desarrolladores.
- Firma, notarización y consentimiento quedan visibles y verificables.
- Se evita ejecutar directamente un script remoto cambiante.
- Los usuarios finales no necesitan comprender comandos de shell.

### Costes y límites

- Requiere Apple Developer Program, identidad de producto definitiva y una
  cadena de build con Xcode.
- La incorporación nativa y la migración del agente requieren implementación y
  pruebas adicionales.
- Apple puede volver a solicitar permisos después de cambios relevantes de la
  app o de macOS; TidyDrop debe detectarlo y fallar cerrado.

## Alternativas descartadas

- `curl | sh`: cómodo en apariencia, pero insuficiente como experiencia y
  frontera de confianza para una app macOS distribuida.
- Pedir al usuario que compile: conserva el canal técnico, no resuelve la
  distribución general.
- PKG con scripts privilegiados: añade privilegios y complejidad innecesarios
  para una aplicación que debe operar en el contexto del usuario.
- Auto-updater en esta etapa: ampliaría la superficie de red y supply chain
  antes de cerrar el canal base.
