# Stack (repositorio Butake-Stack)

Fuente única de reglas para agentes (`CLAUDE.md` y `GEMINI.md` remiten aquí). Lo explicativo está en
`docs/` (índice en [docs/README.md](docs/README.md)); el mapa de carpetas, en
[docs/mapa-del-repositorio.md](docs/mapa-del-repositorio.md).

Stack, de Butake: entorno de desarrollo local para macOS. Producto canónico: SwiftUI/AppKit en
`native/`, motor Rust en `engine/` (CLI JSON + daemon supervisor). Sin WebView.

## Nombre e identificadores

- El producto se llama «Stack» en todo lo visible. El código y los identificadores internos siguen
  diciendo «butake»: bundle `cl.butake.stack.native`, `butakestack://`, Llavero `cl.butake.stack.*`,
  agente `cl.butake.stack.daemon`, binario `butake-stack`, módulo `ButakeStack`, variables `BUTAKE_*`.
  No renombrarlos.
- Ningún nombre de aplicaciones o gestores de terceros que Stack reemplaza o evita, en la interfaz, el
  sitio, la documentación ni los commits. Los productos que Stack administra (PHP, Node.js, MySQL,
  Redis, Caddy…) sí se nombran. `lint-ui.sh` lo cuenta (`third-party`).

## Qué se puede y qué no

- Trabajar en `develop` (o en una rama corta desde `develop`). `main` es promoción y publicación: sin
  push directo.
- No publicar, crear remotos, etiquetas ni hacer push salvo instrucción del usuario.
- No cambiar `BUILD=` de `scripts/build-native.sh` ni `VERSION` salvo instrucción.
- Código y archivos nuevos en inglés; texto visible en español, siempre con `L(…)` y
  `native/Sources/ButakeStack/Resources/es.lproj/Localizable.strings`.
- El usuario configura todo desde la interfaz: proyecto, carpeta, dominio local, lenguaje y versión,
  servicios. La configuración vive en la carpeta de datos (`~/Library/Application Support/Stack/`, o la
  del nombre anterior hasta que el usuario la mueve; ver [docs/operations.md](docs/operations.md)), nunca
  en el repositorio del proyecto. Proyectos nuevos en `~/Stack/Projects` por defecto.
- Sin interpolación de shell: cada proceso recibe ejecutable y argumentos separados. Validar rutas
  (canonicalizar), dominios (`[a-z0-9-]` + TLD permitido) y puertos.
- Acciones con privilegio (resolver `/etc/resolver/<tld>`, confiar la CA local) solo con confirmación
  explícita y el diálogo de administrador de macOS; nunca guardar la clave.
- No detener aplicaciones de terceros sin confirmación en la interfaz; mostrar quién ocupa cada puerto
  antes de tomarlo.
- Herramientas: código dentro de la app firmada, nada descargado. Sus métodos responden
  `plugin_disabled` apagadas; apagadas no dejan nada visible fuera de Ajustes › Herramientas. Para
  agregar una: [docs/como-agregar-una-herramienta.md](docs/como-agregar-una-herramienta.md).

## Secretos

- No leer, copiar ni registrar valores del `.env` de los proyectos; de un `.env` cualquiera solo se lee
  qué claves existen y los puertos. Única excepción (P-29): el supervisor lee el `.env` **escrito por
  Stack** para pasarlo a los procesos del proyecto, con estos límites, todos obligatorios:
  - solo si el proyecto tiene un entorno activo y «Pasar el entorno activo a los procesos» activado, y
    solo al iniciar cada proceso;
  - solo el `.env` de la carpeta del proyecto, archivo regular (nunca un enlace), de 1 MiB o menos, cuya
    primera línea es la cabecera de Stack («Entorno «…» aplicado por Stack…»); un `.env` escrito a mano
    no se lee;
  - los valores van solo al ambiente del proceso, en memoria: nunca a su especificación, a registros,
    respuestas, errores ni al almacén (el registro dice cuántas variables); las `DYLD_*` no pasan;
  - el único lector es `read_stack_dotenv` (`engine/src/web/projects/envs/dotenv.rs`). Para saber si un `.env` es de
    Stack se lee solo su primera línea (`written_by_stack`); reescribirlo cuando cambia un puerto usa
    los valores del almacén, nunca los del archivo.
- La app solo lee un `.env` cuando el usuario pide «Importar» en Entornos (los secretos van al Llavero).
- Contraseñas de servicios propios en el Llavero, salvo las que el motor necesita para administrarlos
  sin la app (`config/<servicio>/`, 0600; ver [docs/architecture.md](docs/architecture.md#seguridad)).
- Secretos de Entornos: un ítem por proyecto y entorno (`EnvSecrets`); no volver a ítems por variable
  ni leer valores para pintar una pantalla (los nombres están en los atributos).
- Cuentas de GitHub y Bitbucket (herramienta Git): un ítem por cuenta (`GitHostingVault`); la ficha
  solo va a la API del proveedor, nunca al motor, a Git, a disco ni a la interfaz (R19).
- Herramienta Git: Stack no abre la app Butake Git. «Traer mis repositorios» solo lee las preferencias
  de esa app y no copia sus cuentas.
- Toda regla nueva sobre datos personales o secretos pasa a `.compliance/` como requisito `R<n>`.

## Firma y Llavero

- `scripts/build-native.sh` firma motor y app con una identidad estable (`scripts/signing.sh`) y un
  requisito designado fijo, sin derechos. No agregar entitlements ni cambiar identificadores sin revisar
  [docs/operations.md](docs/operations.md#firma) («Firma»: orden de elección de la identidad y qué pasa
  con el Llavero al cambiarla).

## Seguridad y datos reales

- QA contra proyectos y datos temporales (`BUTAKE_STACK_HOME`, `HOME` y `BUTAKE_DEVTOOLS_HOME`
  temporales); nunca mutar bases, proyectos, la Bóveda ni el Llavero reales para probar.
- Programas externos en pruebas y QA (gcloud, cloudflared, aws, proveedores de Git): siempre un doble
  local; nunca la cuenta real del usuario, ni crear túneles o registros DNS reales.
- Herramienta Git: pruebas y QA con una copia inventada de las preferencias de Butake Git en un `HOME`
  temporal, nunca con sus datos ni su Llavero reales.
- Pruebas: almacén en memoria (`MemoryKeychainItems`). Contra el Llavero real, solo servicios
  `cl.butake.stack.qa.*` creados y borrados por la propia prueba, sin diálogos.
- No tocar `/Applications/Stack.app` al probar; sin clics ni teclas simulados; nunca `pkill` por patrón.
- Datos de ejemplo inventados en código, pruebas, capturas y documentación: ni correos, ni rutas, ni
  nombres de proyectos o cuentas reales del usuario.

## Interfaz

- Seguir [docs/estandar-ui.md](docs/estandar-ui.md) (glosario, prácticas y arquitectura de información).
- Lo compartido va en `Shared/`; el código de QA solo tras `#if DEBUG` y en `QA/`.
- Operable por IA: todo control con `accessibilityIdentifier` estable.
- Verificar visualmente los cambios de interfaz ([docs/pruebas-y-qa.md](docs/pruebas-y-qa.md#qa-visual)).

## Cadena de validación

```bash
cargo fmt --manifest-path engine/Cargo.toml -- --check
cargo clippy --locked --all-targets --manifest-path engine/Cargo.toml -- -D warnings
./scripts/lint-ui.sh && ./scripts/test-native.sh && ./scripts/build-native.sh && git diff --check
```

`lint-ui.sh` falla si un contador supera su tope de `scripts/lint-ui.baseline`; los topes solo bajan
(`--update`). Detalle y cómo correr una prueba sola: [docs/pruebas-y-qa.md](docs/pruebas-y-qa.md).

## Commits

- En español, convencionales (`feat(área): …`, `fix: …`, `docs: …`, `chore: …`), pequeños y con un
  solo tema.
- Sin coautoría de IA ni líneas de atribución.

Plan, informes y bitácora locales: `internal/` (no versionado). Patrón de referencia: `../Butake-Git`.
