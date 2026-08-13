# ADR-0004: Community Preview sin Developer ID

- Estado: Aceptado
- Fecha: 2026-08-13
- Decisores: propietario del proyecto y Codex
- Alcance: canal gratuito y temporal para contribuidores y usuarios informados
- Relacionado: [ADR-0002](0002-distribution-updates-and-tcc-continuity.md) y [ADR-0003](0003-end-user-installation-experience.md)

## Contexto

La aplicación Universal 2, la incorporación AppKit y el agente incluido ya se
pueden construir y validar, pero el proyecto no dispone todavía de una membresía
Apple Developer Program. Sin ella no existen certificado Developer ID ni
notarización. El repositorio público por sí solo tampoco ofrece una aplicación:
los usuarios necesitan un artefacto binario real en GitHub Releases.

Apple permite que una persona abra una aplicación de un desarrollador no
identificado mediante una excepción explícita en Privacy & Security. Esa acción
reduce la comodidad y Apple advierte correctamente que solo debe utilizarse con
software cuya procedencia se haya comprobado. Una firma ad hoc no aporta una
identidad verificada por Apple y puede causar nuevas decisiones de Gatekeeper o
TCC después de cada actualización.

## Decisión

TidyDrop tendrá un canal temporal denominado **Community Preview**:

- DMG precompilado Universal 2 para `arm64` y `x86_64`;
- bundle ID público `io.github.bugroo.tidydrop`;
- app, CLI y agente firmados ad hoc con Hardened Runtime;
- build exclusivo en GitHub Actions desde un tag que pertenezca a `main`;
- checksum SHA-256 y GitHub Artifact Attestation para el DMG y su checksum;
- publicación como prerelease, nunca como `latest` ni como versión estable;
- aviso visible dentro de la app antes de permitir apply;
- dry-run obligatorio después de instalar o actualizar;
- identidad de build ligada al tag comunitario para que cada actualización
  vuelva a dry-run aunque conserve la versión corta;
- descarga únicamente desde `github.com/bugroo/tidydrop/releases`.

La firma ad hoc, el checksum y la atestación cumplen funciones diferentes. La
firma conserva la estructura de integridad de código local; el checksum detecta
un archivo distinto; la atestación vincula el artefacto con el workflow,
repositorio y commit que lo construyeron. Ninguno sustituye Developer ID,
notarización o la revisión de Apple.

## Experiencia de instalación

1. Descargar el DMG desde la prerelease oficial.
2. Arrastrar `TidyDrop.app` a Applications.
3. Intentar abrir la app y aceptar que macOS la bloquee inicialmente.
4. Usar `System Settings → Privacy & Security → Open Anyway`.
5. Permitir el background item y la carpeta seleccionada cuando macOS lo pida.
6. Registrar el agente y completar una pasada verificada con `dry-run`,
   `moved=0` y `errors=0`.
7. Activar movimientos solo mediante una decisión posterior y explícita.

Las instrucciones no desactivarán Gatekeeper, no eliminarán el atributo de
cuarentena, no usarán `curl | sh`, no solicitarán Full Disk Access y no
modificarán TCC.

## Gates de publicación

La prerelease se publica únicamente si:

1. todos los tests, builds y auditorías del repositorio pasan;
2. el bundle y el DMG pasan los gates específicos del canal `community`;
3. el workflow está fijado por SHA, no consume secretos Apple y usa permisos
   mínimos de GitHub;
4. el DMG y checksum se atestiguan antes de crear la Release;
5. la Release se crea como draft y sus assets se vuelven a descargar;
6. checksum, DMG y atestación pasan sobre esa descarga;
7. solo entonces el draft se publica como prerelease y `latest=false`;
8. una instalación con cuarentena demuestra la advertencia esperada,
   incorporación, agente, TCC, dry-run y desinstalación segura.

## Actualizaciones y TCC

Cada Community Preview se considera una nueva identidad operativa a efectos de
riesgo. Una actualización vuelve a dry-run y repite la verificación de la app y
del agente. macOS puede volver a pedir Open Anyway, Login Items o Files &
Folders. TidyDrop no interpreta una autorización anterior como garantía.

## Consecuencias

### Ventajas

- La comunidad puede instalar un DMG sin compilar ni pagar la membresía del
  proyecto.
- El build es trazable hasta un commit público y reproducible.
- Se conserva un flujo macOS comprensible, sin scripts remotos ni privilegios.
- El canal permite obtener experiencia real antes de una release notarizada.

### Costes y límites

- Gatekeeper muestra una advertencia y exige una excepción manual.
- Apple no verifica la identidad del desarrollador ni analiza el artefacto.
- Las actualizaciones pueden repetir permisos y avisos.
- No se presenta como apropiado para distribución masiva o usuarios que no
  comprendan la excepción de seguridad.
- Homebrew oficial no es una solución alternativa mientras la app requiera
  evitar manualmente Gatekeeper.

## Relación con el canal estable

Este ADR no reemplaza el objetivo de ADR-0002 y ADR-0003. La primera release
estable para público general seguirá exigiendo Developer ID, notarización,
Gatekeeper aprobado sin excepción, TCC probado y hardware real compatible. El
canal Community Preview se retirará o quedará como beta cuando exista esa
distribución.

## Referencias

- [Apple: abrir una app de un desarrollador desconocido](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac)
- [Apple Developer ID](https://developer.apple.com/support/developer-id/)
- [GitHub Releases](https://docs.github.com/repositories/releasing-projects-on-github/managing-releases-in-a-repository)
- [GitHub Artifact Attestations](https://docs.github.com/actions/security-for-github-actions/using-artifact-attestations)
- [Homebrew Acceptable Casks](https://docs.brew.sh/Acceptable-Casks)
