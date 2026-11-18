# Cómo agregar una herramienta

Pasos y archivos, tal como se agregaron Google Cloud (`gcp`) y Git (`git`). Antes de empezar, decidir
si es de verdad una herramienta: solo **agrega** páginas, acciones y datos propios, y la base no depende
de ella ([herramientas.md](herramientas.md#qué-es-base-y-qué-es-herramienta)). El código va dentro de la
app firmada; nada se descarga.

En los ejemplos, la herramienta nueva se llama «Ejemplo», con id `ejemplo` y prefijo de métodos `ejemplo`.

## 1. Catálogo (`engine/src/app/plugins.rs`)

- Agregar un `Spec { id: "ejemplo", version: "1.0.0", requires: &[…] }` a `CATALOG`. `requires` nombra
  piezas de la base (`keychain`, `ssh-keys`, `daemon`) o del sistema (`/usr/bin/ssh`, `git`, `gcloud`).
- Si guarda datos propios: una rama en `has_data` y, en `remove`, lo que borra con `deleteData`.
- Si deja algo corriendo (túneles, reenvíos): una rama en `stop`, que se llama al apagarla y al quitarla.
- Si su estado vive fuera de `plugins.json` (como Correo y Dumps en `stack.json`), seguir `is_receiver`.
- Sin `plugins.json` una herramienta nueva queda apagada. No cambiar ese comportamiento para las
  instalaciones existentes.

## 2. Motor

- Módulo propio: `engine/src/ejemplo/mod.rs` con `pub fn dispatch(store, method, request)` y un
  `match` por método. `mod ejemplo;` en `engine/src/main.rs`.
- La barrera es una sola: `app::plugins::tool_of` dice a qué herramienta pertenece cada método y
  `dispatch_with` (`main.rs`) la exige antes de todo. Agregar el prefijo (o la lista) ahí y el despacho
  a su módulo, **antes** de los despachadores generales:

  ```rust
  // app/plugins.rs, tool_of
  } else if method.starts_with("ejemplo") {
      Some("ejemplo")
  // main.rs, dispatch_with: la compuerta ya corrió; solo el despacho
  Some("ejemplo") => return ejemplo::dispatch(store, method, request),
  ```

  Si el prefijo choca con un método de la base (como `gitStatus`), usar una lista explícita, como
  `git::METHODS` con `git::is_method`. La prueba `every_tool_method_answers_plugin_disabled_while_off`
  (`app/plugins.rs`) encuentra los métodos nuevos sola.
- Errores: códigos fijos `ejemplo_*`, agregados a `PUBLIC_ERRORS` en `main.rs`, cada uno con su
  `error.<código>` en los textos (`error_texts_tests.rs` lo comprueba). Nunca devolver la salida de un
  programa externo ni datos del pedido.
- Una línea de comandos externa de la herramienta (como AWS CLI y gcloud): con `core/cli_tool.rs`, que
  arma el entorno mínimo, el tiempo límite, la cancelación y los códigos fijos.
- Programas externos: con `core/process.rs` (ejecutable y argumentos separados, entorno mínimo) y, si
  esperan red o al usuario, con `core/watch.rs` y una carpeta de procesos en curso (`ejemplo-runs/`, como
  `aws-runs/` y `gcp-runs/`).
- Escrituras: `core/json.rs` y `core/fsutil.rs` (atómicas, 0600). Lo que escribe en archivos ajenos se
  respalda antes (como `aws-backups/`).
- Lo que cambia algo exige `confirmed` (`confirmation_required`).

## 3. App

| Archivo | Qué agregar |
|---|---|
| `native/Sources/ButakeStack/Ejemplo/` | Carpeta propia: `EjemploTool.swift` (estado), `EjemploPage.swift` (detalle), `EjemploList.swift` (columna de contenido), modelos y hojas. Una herramienta de cuentas de nube usa `Shared/Cloud/` (lista, fila y cabecera de tarjeta) |
| `Tools/ToolPage.swift` | `case "ejemplo": EjemploPage(store: store)` |
| `App/ContentColumn.swift` | `.tool("ejemplo")` en `hasContentColumn` y su lista en `body`, con `where store.canShow(store.route)` |
| `App/SidebarLayout.swift` | El id en `tools` (lo que se usa) o en `clouds` (cuentas de un proveedor), en su orden |
| `Tools/ToolInfo.swift` | `dataPath` si guarda datos, para «Mostrar datos» |
| `Shared/TechCatalog.swift` | `Tech.of("ejemplo")`: título, logo (`Logos/`) o símbolo, y color de su ficha (sin repetir el de otra fila) |
| `Shared/Symbols.swift` | Los símbolos nuevos; nunca un literal en una vista |
| `App/CommandPalette.swift`, `App/AppCommands.swift` | Entradas de la paleta y del menú, si las tiene |
| `App/StackStore+Links.swift` | Solo si necesita un enlace propio: `butakestack://tool/ejemplo` ya funciona y, apagada, abre su fila en Ajustes |

Seguir [estandar-ui.md](estandar-ui.md): tres columnas, acciones en la barra de herramientas,
`Form(.grouped)`, `ContentUnavailableView` para el vacío, identificadores `ejemplo.<elemento>` en todo
control, archivos de menos de 400 líneas.

Si usa otra herramienta (por ejemplo, abrir algo en la Terminal), comprobar `store.pluginEnabled(…)` y,
si está apagada, llevar a su fila con `store.openTool(…)`.

## 4. Textos

En `Resources/es.lproj/Localizable.strings`, que está ordenado por área: se agrega el prefijo nuevo
(`ejemplo`) con su encabezado a la tabla `AREAS` de `scripts/order-strings.py` y se corre
`scripts/order-strings.py --write`, que deja cada clave en su lugar (`lint-ui.sh` lo comprueba):

- `plugin.ejemplo.title`, `plugin.ejemplo.summary`, `plugin.ejemplo.row` y
  `plugin.ejemplo.deleteDataDetail` (obligatorios: `LocalizationTests` los exige por cada herramienta del
  catálogo).
- `error.ejemplo_*` para cada código público.
- Las claves de la página con el prefijo `ejemplo.*`, solo con términos del glosario.

## 5. QA

- Ganchos en `QA/QAHooks.swift` (variables `BUTAKE_QA_EJEMPLO*`), todo tras `#if DEBUG`.
- Si llama a un programa externo, un doble: un binario falso como `engine/src/gcp/testdata/gcloud`, o un
  servidor falso local como `QA/GitHostingFakeServer.swift`. Nunca la cuenta real.
- Capturas en claro y oscuro de la página llena, vacía y apagada. Ver [pruebas-y-qa.md](pruebas-y-qa.md).

## 6. Pruebas

- Motor: que cada método responde `plugin_disabled` con la herramienta apagada (como
  `git/tests/dispatch.rs`), que activar la registra (`app/plugins.rs`), y el comportamiento con el doble.
- Si guarda o toca secretos: una prueba con valor centinela que no debe aparecer en el almacén, los
  registros, las respuestas ni la interfaz.
- App: su lista en `everyToolWithAListUsesTheContentColumn` (`ToolsTests.swift`), su orden en
  `toolsAndCloudFollowTheirOrder` y que su ícono no repite otro (`SidebarTests.swift`).
- Cadena completa en verde y `lint-ui.sh` sin subir ningún tope.

## 7. Cumplimiento y documentación

- Si toca datos personales, credenciales o envía algo fuera del Mac: un requisito de privacidad nuevo,
  con su revisión y su evidencia.
- `docs/herramientas/ejemplo.md` con las mismas secciones que las demás (qué hace, cómo se activa,
  métodos, datos, seguridad, enlaces, límites), su fila en [herramientas.md](herramientas.md), en
  [mapa-del-repositorio.md](mapa-del-repositorio.md) y en [README.md](README.md).
- Una línea en [decisiones.md](decisiones.md) si la herramienta trae una decisión de producto.
