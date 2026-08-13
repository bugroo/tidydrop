# Fase 1: preparación de distribución para terceros

## Resultado de esta etapa

Esta fase prepara una cadena verificable para construir TidyDrop como aplicación Universal 2, firmarla con Hardened Runtime, enviarla a notarización y empaquetarla sin exigir herramientas de desarrollo al receptor.

No convierte por sí sola el build ad hoc actual en una release pública. La distribución real permanece bloqueada hasta disponer de:

- un bundle ID definitivo bajo un dominio controlado;
- Apple Developer Program y una identidad `Developer ID Application` válida;
- un Team ID fijado;
- credenciales de notarización almacenadas fuera del repositorio;
- pruebas en un Mac Intel real y en un Mac limpio sin Xcode/CLT;
- ticket de notarización aceptado y grapado.

## Historias de usuario y aceptación

### P1-1 · Build Universal 2

Como mantenedor, quiero producir un único bundle con slices `arm64` y `x86_64`, para que el mismo artefacto pueda ejecutarse nativamente en ambos tipos de Mac.

Criterios:

- ambos targets compilan para macOS 13 con advertencias como errores;
- `lipo -archs` devuelve exactamente `arm64` y `x86_64`;
- el binario no depende ni conserva rpaths de Xcode o Command Line Tools;
- el bundle conserva las claves TCC y la versión declarada.

Estimación inicial: 2 puntos. Dependencias: ninguna externa. Prioridad: alta.

### P1-2 · Firma y notarización fail-closed

Como receptor, quiero que macOS pueda verificar el editor y el ticket de Apple, para detectar alteraciones y reducir advertencias evitables de Gatekeeper.

Criterios:

- la firma de distribución solo acepta `Developer ID Application`;
- Hardened Runtime y timestamp seguro son obligatorios;
- `get-task-allow` está prohibido;
- notarización usa `notarytool --wait` sin `--force`;
- solo un estado `Accepted` permite grapar y validar el ticket;
- el modo development nunca se presenta como distribución.

Estimación inicial: 3 puntos. Dependencias: Developer ID, Team ID, bundle ID y perfil de notarización. Prioridad: alta.

### P1-3 · CI sin secretos para readiness

Como mantenedor, quiero ejecutar los gates de arquitectura y seguridad en cada PR sin exponer credenciales de firma.

Criterios:

- `GITHUB_TOKEN` tiene únicamente `contents: read`;
- checkout no persiste credenciales y está fijado a un SHA completo;
- no se usan `pull_request_target`, runners propios ni acciones de terceros;
- el workflow prueba el producto y un artefacto Universal 2 ad hoc en `/private/tmp`;
- los secretos de release no existen en el workflow de PR.

Estimación inicial: 2 puntos. Dependencias: GitHub Actions macOS. Prioridad: alta.

### P1-4 · Release firmada real

Como mantenedor, quiero emitir un ZIP firmado y notarizado con checksum, para poder probarlo en un Mac limpio antes de compartirlo.

Criterios:

- pasan `codesign --deep --strict`, Team ID, designated requirement, `spctl` y `stapler validate`;
- el ZIP extraído vuelve a pasar los mismos gates;
- el checksum externo pasa desde el directorio que contiene ZIP y `.sha256`;
- instalación limpia, actualización, TCC y dry-run se prueban en hardware real;
- no se publica un release si falta un gate.

Estimación inicial: 5 puntos. Dependencias: P1-1 a P1-3 y credenciales Apple. Prioridad: alta, bloqueada externamente.

## Comandos de la cadena

Build y verificación de desarrollo, siempre en un directorio temporal:

```sh
./scripts/build-universal-app.sh \
  /private/tmp/TidyDrop.app \
  com.local.tidydrop

./scripts/sign-app.sh /private/tmp/TidyDrop.app --adhoc
./scripts/verify-release.sh /private/tmp/TidyDrop.app development
```

Firma de distribución, una vez fijados identidad y bundle ID:

```sh
./scripts/sign-app.sh \
  /private/tmp/TidyDrop.app \
  --developer-id \
  "Developer ID Application: NOMBRE (TEAMID)"
```

Notarización. El perfil se crea fuera del repositorio y el script nunca almacena su secreto:

```sh
TIDYDROP_RELEASE_BUNDLE_ID="ID.DEFINITIVO" \
TIDYDROP_RELEASE_TEAM_ID="TEAMID" \
./scripts/notarize-app.sh \
  /private/tmp/TidyDrop.app \
  --keychain-profile tidydrop-notary
```

Gate y empaquetado final:

```sh
TIDYDROP_RELEASE_BUNDLE_ID="ID.DEFINITIVO" \
TIDYDROP_RELEASE_TEAM_ID="TEAMID" \
./scripts/package-release.sh \
  /private/tmp/TidyDrop.app \
  /private/tmp/TidyDropRelease \
  distribution
```

## Fronteras de seguridad

- El runtime de TidyDrop continúa sin red. Solo `notarize-app.sh`, ejecutado por el mantenedor, contacta al servicio de Apple.
- No se incorporan certificados, `.p12`, claves API, perfiles, logs de notarización o valores de secretos al repositorio.
- La firma se hace de dentro hacia fuera; `--deep` se usa para verificar, no para firmar.
- `--force` está prohibido en la subida de notarización porque omitiría fallos de preflight.
- Los artefactos de development incluyen una firma ad hoc y un nombre que impide confundirlos con una release.
- La firma y los timestamps hacen que el ZIP final no sea reproducible byte a byte. Lo reproducible es el procedimiento, el commit, las versiones del toolchain y los gates registrados.

## CI y coste

El workflow de readiness usa el runner GitHub-hosted `macos-15` y fija Xcode 16.4 mediante `DEVELOPER_DIR`. Ese runner construye ambos slices; el slice Intel todavía debe ejecutarse en un runner/host Intel real antes de distribuir. No se usa un runner propio porque un runner persistente ampliaría el impacto de código no confiable.

El repositorio es público desde el 13 de agosto de 2026, por lo que GitHub Artifact Attestations está disponible en el plan actual. Todavía no se convierte en gate porque esta fase no publica un artefacto Developer ID/notarizado; debe añadirse al workflow que produzca la primera release real, junto con checksum, firma, notarización y evidencia de procedencia.

## Fuentes primarias vigentes consultadas

- [Apple: Building a universal macOS binary](https://developer.apple.com/documentation/apple-silicon/building-a-universal-macos-binary)
- [Apple: Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)
- [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple: Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Apple: Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)
- [GitHub: Secure use reference](https://docs.github.com/en/actions/reference/security/secure-use)
- [GitHub: Workflow syntax and token permissions](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)
- [GitHub: Runner images](https://github.com/actions/runner-images)
- [GitHub: Artifact attestations](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations)
