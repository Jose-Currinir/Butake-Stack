# Pruebas y QA

Cómo se prueba Stack sin tocar datos reales. Las reglas obligatorias están en
[AGENTS.md](../AGENTS.md#seguridad-y-datos-reales); aquí, el cómo.

## Cadena de validación

La misma que corre la integración continua (`.github/workflows/native.yml`), en este orden:

```bash
cargo fmt --manifest-path engine/Cargo.toml -- --check
cargo clippy --locked --all-targets --manifest-path engine/Cargo.toml -- -D warnings
./scripts/lint-ui.sh
./scripts/test-native.sh
./scripts/build-native.sh
git diff --check
```

`scripts/test-native.sh` crea un `BUTAKE_STACK_HOME` temporal (lo borra al salir), apunta
`BUTAKE_STACK_ENGINE` al motor de depuración (solo las compilaciones de depuración la leen: la app publicada usa el motor de su paquete) y corre, en orden: `cargo test`, `cargo build` (las
pruebas de la app llaman al motor real), las pruebas Python de `scripts/php/tests`, `swift test` y
`lint-ui.sh`.

## Qué cubre cada conjunto

| Conjunto | Dónde | Cubre |
|---|---|---|
| Motor, en línea | `#[cfg(test)]` en cada archivo de `engine/src/`, o en `<archivo>_tests.rs` junto a los de más de 800 líneas | Validación, almacén, entornos, redacción de registros, catálogo de herramientas (todo método de una herramienta apagada responde `plugin_disabled`), servicios, AWS, Google Cloud, renombrar; `error_texts_tests.rs`: cada código de error público tiene su `error.<código>` |
| Git | `engine/src/git/tests/` (un archivo por tema) | Cada guarda de la herramienta con repositorios temporales y Git aislado; `dispatch.rs` comprueba que todo `git*` responde `plugin_disabled` apagada |
| Integración del motor | `engine/tests/cli.rs`, `daemon.rs`, `aws.rs`, `migrate.rs` | El binario de punta a punta: CLI, daemon real en un almacén temporal, AWS con un `aws` falso, traslado de la carpeta de datos |
| PHP propio | `scripts/php/tests/` | Fabricación y empaquetado de PHP |
| App | `native/Tests/ButakeStackTests/` (un archivo por área) | Bóveda, Git (piezas, proveedores, historial, flujo), entornos y Llavero, barra lateral, proyectos de varias partes, renombrar, base de datos, herramientas, Correo y Dumps (`ReceiverToolsTests`), claves SSH y cuentas de nube (`KeysAndCloudTests`), ventana, textos |
| Candado de interfaz | `scripts/lint-ui.sh` | Las prácticas de [estandar-ui.md](estandar-ui.md) que se pueden contar por texto |

`LocalizationTests` y `EngineTests` llaman al motor real (`pluginCatalog`…): sin `cargo build`
previo fallan. `GitPiecesPerformanceTests` mide tiempos y puede fallar en un equipo muy cargado.
Ninguna prueba lee la documentación.

Las pruebas de la app corren en paralelo y comparten el almacén temporal de `test-native.sh`: una
prueba que depende de qué herramientas están encendidas usa un almacén propio (`isolatedEngine()`), y
toda lectura con índice de una lista que viene del motor pasa antes por `#require` (un índice fuera de
rango cierra todo `swift test` en vez de fallar una sola prueba). El motor escribe `plugins.json` bajo
el candado del almacén, así que dos procesos que encienden herramientas a la vez conservan ambos
cambios. Un cierre con la señal 5 (`SIGTRAP`) deja su informe en `~/Library/Logs/DiagnosticReports`
(`swiftpm-testing-helper-*.ips`), con la pila del hilo que falló.

## Correr uno solo

```bash
# Motor: por nombre (subcadena) o por archivo de integración
cargo test --manifest-path engine/Cargo.toml a_rename_reaches_every_place
cargo test --manifest-path engine/Cargo.toml --test cli

# App: compilar antes el motor y darle un almacén temporal
cargo build --manifest-path engine/Cargo.toml
BUTAKE_STACK_HOME="$(mktemp -d)/store" \
BUTAKE_STACK_ENGINE="$PWD/engine/target/debug/butake-stack" \
  xcrun swift test --disable-sandbox --package-path native --filter VaultImportLinkTests

# Candado con cada hallazgo
LINT_UI_VERBOSE=1 ./scripts/lint-ui.sh
```

## QA visual

Solo con la compilación de depuración: todo el código de QA está en `native/Sources/ButakeStack/QA/`
tras `#if DEBUG` y no llega a la app publicada.

El servidor falso de proveedores (`QA/GitHostingFakeServer.swift`) y las galerías (`QA/GitPiecesQA.swift`)
se quedan en `QA/` y no en `native/Tests/`: la app de depuración los usa en la QA visual
(`BUTAKE_QA_GIT_HOSTING=fake`, rutas de las galerías) y un paquete de Swift no puede enlazar código del
destino de pruebas en el ejecutable ni elegir dependencias por configuración. Las pruebas los usan a
través de `@testable import`. Cada vista de producción que necesita un gancho lo pide con un
`#if DEBUG` corto que llama a `QAHooks` (79 en 71 archivos, revisión de R-1): reunirlos en un punto por
área exige mover estado de las vistas (hojas y selecciones con `@State`), así que no es mecánico y queda
para cuando se toque cada área.

```bash
xcrun swift build --disable-sandbox --package-path native
QA_HOME="$(mktemp -d)"
BUTAKE_QA_WINDOW=1 \
BUTAKE_STACK_HOME="$QA_HOME/store" \
BUTAKE_STACK_ENGINE="$PWD/engine/target/debug/butake-stack" \
BUTAKE_QA_ROUTE="tool:git" \
BUTAKE_QA_SNAPSHOT="$QA_HOME/git.png" \
  native/.build/debug/ButakeStack
```

- `BUTAKE_QA_WINDOW=1` abre la ventana al iniciar y activa los ganchos; sin ella, ninguna variable
  `BUTAKE_QA_*` hace nada.
- `BUTAKE_QA_ROUTE`: `home`, `site:<id>`, `composite:<id>`, `service:<categoría>`,
  `language:<id>`, `tool:<id>`, `utilities[:<sección>]`; varios unidos con `>` cambian de página
  uno tras otro.
- `BUTAKE_QA_SNAPSHOT=<png>` guarda una captura de la ventana (`BUTAKE_QA_SIZES=minimum,normal,screen`
  y `{size}` en la ruta para varias); `BUTAKE_QA_WINDOW_SIZE=<ancho>x<alto>` fija el tamaño.
- El gancho de disposición (`QA/QALayout.swift`) escribe una línea `QA layout:` por captura, con
  `LAYOUT FAIL` cuando una columna empieza bajo la barra de título y `TOOLBAR OVERLAP` cuando dos
  controles de la barra se cruzan.
- Cada pantalla tiene sus variables (`BUTAKE_QA_GIT`, `BUTAKE_QA_VAULT=<carpeta>`, `BUTAKE_QA_AWS`,
  `BUTAKE_QA_GCP`, `BUTAKE_QA_RENAME`…): todas se leen en `QA/QAHooks.swift`, salvo las de la Bóveda
  (`QA/VaultQA.swift`, ver [boveda-formato.md](boveda-formato.md#qa)).
- Las capturas usan la ventana sin tomar el teclado. Sin clics ni teclas simulados.

## Dobles y aislamiento

| Qué se reemplaza | Cómo |
|---|---|
| Carpeta de datos | `BUTAKE_STACK_HOME` temporal; DNS en 1053 y resolver y CA simulados dentro del almacén |
| Carpeta personal de las utilidades | `BUTAKE_DEVTOOLS_HOME`: instalaciones, `~/.aws` y la carpeta de aplicaciones quedan dentro |
| Llavero | `MemoryKeychainItems` en las pruebas; con un almacén de QA los servicios llevan `.qa` (`cl.butake.stack.db.qa`, `.vault.qa`, `.aws.qa`) |
| AWS CLI | Un `aws` falso en un `HOME` temporal (`engine/tests/aws.rs`) |
| gcloud | `engine/src/gcp/testdata/gcloud` con cuentas inventadas y `CLOUDSDK_CONFIG` temporal |
| cloudflared | Un `cloudflared` falso en el `PATH` de prueba (`web/net/tunnels.rs`) |
| GitHub y Bitbucket | Servidor falso en 127.0.0.1 (`QA/GitHostingFakeServer.swift`, `BUTAKE_QA_GIT_HOSTING=fake`) |
| Git | Repositorios y remotos locales temporales con `HOME` y configuración global propios, sin agente SSH |
| Butake Git | Una copia inventada de su archivo de preferencias en un `HOME` temporal |
| Respaldo de la Bóveda | `native/Tests/ButakeStackTests/VaultBackupFixture.swift` (datos inventados) |

Varias pruebas siembran **valores centinela** (una contraseña, una ficha, una credencial) y
comprueban que no aparecen en el almacén, los registros, las respuestas del motor ni la interfaz.

## Lo que nunca se hace al probar

- Usar el almacén, los proyectos, las bases, la Bóveda, el Llavero o las cuentas reales del usuario.
- Ejecutar el `cloudflared`, el `gcloud` o el `aws` reales contra cuentas reales, ni crear túneles o
  registros DNS.
- Tocar `/Applications/Stack.app` (no usar `scripts/install-native.sh` en QA).
- Detener procesos por patrón (`pkill -f`) o reiniciar el daemon real del usuario.
