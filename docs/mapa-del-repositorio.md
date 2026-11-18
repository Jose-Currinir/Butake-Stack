# Mapa del repositorio

Dónde vive cada cosa. Una línea por carpeta y por archivo importante. Para el porqué, ver
[architecture.md](architecture.md).

## Raíz

```
README.md            presentación, instalar, compilar, índice
VERSION              versión de la app (única fuente; la lee build-native.sh y el sitio)
LICENSE
.github/workflows/   native.yml (validación en macOS) y pages.yml (sitio)
docs/                documentación (índice en docs/README.md); docs/presentacion/ capturas del sitio
engine/              motor Rust: CLI JSON + daemon (binario butake-stack)
native/              app SwiftUI/AppKit (paquete Swift ButakeStack)
scripts/             compilar, probar, firmar, empaquetar, candado de interfaz, PHP propio
site/                sitio público (Astro, GitHub Pages)
internal/            planes, informes y evidencia locales; ignorado por Git, no se publica
```

## Motor: `engine/src/`

```
main.rs              despacho (compuerta única de herramientas: app::plugins::tool_of) y por dominio, códigos de error públicos, subcomandos
                     (daemon, watch-status/-logs/-dumps, dbsession, aws-credential, git-console,
                     git-write-plan, migrate-data, replace-app; ayudante askpass)
core/                piezas únicas compartidas (cli_tool.rs: línea de comandos de AWS y Google Cloud)
  model.rs           tipos y validación: StackConfig, Project, ProjectKind, GcpLink
  store.rs           carpeta de datos (Store::resolve), proyectos, groups.json (SiteGroup), relocate
  json.rs fsutil.rs  JSON con escritura atómica privada; archivos 0600 sin seguir enlaces
  journal.rs         cambios de varios archivos que se aplican enteros o se revierten
  process.rs watch.rs  procesos sin shell; hijos que esperan red o usuario y nunca quedan huérfanos
  download.rs archive.rs hash.rs signature.rs  descargas HTTPS, extracción, sumas, firma de Apple
  github.rs cache.rs fuente de versiones de GitHub con mínimo uso de su API; caché de catálogos
  progress.rs        progreso de operaciones largas
  validate.rs codec.rs rand.rs time.rs
app/                 la app misma
  plugins.rs         catálogo de herramientas, activar, quitar, plugin_disabled
  dispatch.rs        pluginCatalog, stackConfig, exportar y restaurar la configuración, setMail/setDumps
  backup.rs          «Mi entorno»: exportar y restaurar sin secretos
  migrate/           traslado de la carpeta de datos al nombre «Stack»
  update.rs          reemplazo de la app al actualizar
daemon/              supervisor
  mod.rs             socket, protocolo, receptores de Correo y Dumps, suscripciones watch-*
  processes.rs       entorno de cada proyecto (SiteRuntime) y especificaciones de los procesos que supervisa
  supervisor.rs      procesos en su grupo, reinicio con espera, apagado ordenado
  logs.rs redact.rs  registros con rotación y filtro de valores secretos
  launch_agent.rs    LaunchAgent cl.butake.stack.daemon y sus sockets
  trust.rs           /etc/resolver/<tld> y confianza de la CA local
  public.rs          conexión con Cloudflare y túneles de dirección fija en marcha
  dispatch.rs        métodos del agente, estado, salud, siteShellEnvironment, puertos
web/                 proyectos y web local (base); mod.rs reparte los métodos entre sus cuatro carpetas
  projects/          proyectos: lista y registros, carpetas, renombrar, nuevo proyecto, Git de la base
    dispatch.rs      sus métodos (envList…, renameProject, createProject, gitStatus, watchedFolders…)
    detect.rs        detectar una carpeta
    scaffold/        crear proyectos con su generador oficial: laravel.rs, web.rs (JavaScript y básicos), apps.rs
    envs/            entornos .env: mod.rs (guardar, activar, exportar, auditoría), ports.rs (marcadores
                     {port:}/{public:}), dotenv.rs (único lector de valores del .env de Stack)
    rename.rs        renombrar y mover un proyecto (pruebas en rename_tests.rs)
    attention.rs service_use.rs  qué necesita cada proyecto; servicios en uso y su interruptor
    watch.rs git.rs  carpetas vigiladas; rama, cambios y worktrees de cada proyecto
  services/          servicios de Stack: setEngine, engineRecipes, bases y cuentas (dispatch.rs)
    engines.rs web_server.rs  recetas de cada servicio; php-fpm y Caddy generados
    databases.rs postgres_auth.rs  bases y cuentas de un proyecto; contraseña del PostgreSQL de Stack
  net/               red local: shareSite (dispatch.rs)
    tunnels.rs       dirección fija (túnel con nombre por proyecto)
    dns.rs listeners.rs  DNS interno, sockets 53/80/443
  tools/             Correo y Dumps: mail*, dumpsClear (dispatch.rs)
    mail.rs dumps.rs servidor SMTP de captura y receptor de VarDumper
runtimes/            lenguajes, versiones, utilidades y extensiones
  dispatch.rs        métodos de lenguajes, utilidades y enlaces de terminal
  languages/         php.rs python.rs toolchains.rs: PHP propio, Python, versiones de Node, Java, Rust y Swift;
                     node_range.rs (rango de Node de un proyecto), usage.rs (qué proyectos usan cada versión)
  utilities/         página Utilidades: mod.rs (registro, instalar, quitar), assistants.rs (asistentes de IA),
                     aws_cli.rs, version_control.rs (Git compilado de su fuente)
    devtools/        herramientas de desarrollo de los perfiles: install.rs, latest.rs (versiones nuevas)
    catalog/         piezas descargables (Node, Caddy, servicios): versions.rs (lo publicado), install.rs (descargar
                     y compilar, OpenSSL de PostgreSQL)
  extensions/        extensiones de los servicios (P-43): catalog.rs, database.rs, project.rs y install/ (build.rs, place.rs)
db/                  herramienta Cliente de bases de datos (ops/ un archivo por grupo de métodos)
  client/            conexiones (mod.rs), túneles SSH (tunnel.rs), clientes de cada motor (run.rs)
ssh/                 herramienta Terminal (hosts, sftp, snippets, config) y base (keys, askpass, common)
  hosts/             hosts guardados (mod.rs), claves de host (known.rs), reenvíos (forwards.rs)
aws/                 herramienta AWS
gcp/                 herramienta Google Cloud (testdata/gcloud: gcloud falso de pruebas)
git/                 herramienta Git (commands.json: diccionario; tests/: pruebas por tema)
skills/              herramienta Skills (índice, enlaces a las carpetas de las IA, papelera, salud, exportar; tests/ por tema)
```

Pruebas del motor: en línea (`#[cfg(test)]`) en los archivos pequeños; en un archivo vecino
`<archivo>_tests.rs` (o `tests.rs` junto a un `mod.rs`) en los de más de 800 líneas: `web/projects/envs/tests.rs`,
`web/projects/scaffold/tests.rs`, `web/projects/detect_tests.rs`, `web/net/tunnels_tests.rs`, `web/projects/rename_tests.rs`,
`web/projects/attention_tests.rs`, `runtimes/languages/python_tests.rs`, `runtimes/utilities/tests.rs`,
`runtimes/utilities/catalog/tests.rs`, `runtimes/utilities/devtools/tests.rs`, `ssh/hosts/tests.rs`, `db/client/tests.rs`, `core/store_tests.rs`,
`core/model_tests.rs`, `daemon/tests.rs`, `app/migrate/tests.rs`; `git/tests/` por tema; y las de
integración en `engine/tests/` (`cli.rs`, `daemon.rs`, `aws.rs`, `migrate.rs`, `fixtures/`).

## App: `native/Sources/ButakeStack/`

```
App/                 entrada, ventana, menús, rutas y estado
  ButakeStackApp.swift AppDelegate.swift ActivationPolicy.swift  ciclo de vida; app normal con ventana
  RootView.swift ContentColumn.swift  tres columnas; qué ruta tiene columna de contenido
  Route.swift RouteStorage.swift  destinos de la barra lateral
  Sidebar.swift SidebarLayout.swift ComponentList.swift  barra lateral y orden de sus bloques
  CommandPalette.swift AppCommands.swift  paleta y menús
  MenuBarPanel.swift StatusBar.swift  panel de la barra de menús; barra inferior de estado
  StackEngine.swift  llamadas al motor (JSON por stdin) y watch-status
  StackStore.swift StackStore+*.swift  estado observable por tema (Links: enlaces butakestack://)
  Onboarding/ Updates/  asistente de configuración; actualizaciones
Projects/            páginas, hojas y menús de proyectos (base)
  Environments/      entornos .env y sus secretos en el Llavero (EnvSecrets)
  Composite/         proyectos de varias partes
  New/               nuevo proyecto
  FixedAddress*.swift ShareSection.swift  dirección fija y temporal
  ProjectRenameSheet.swift ProjectPlace.swift  renombrar y mover; carpeta sugerida al crear
Services/            páginas de servicios por categoría; Extensions/ (extensiones de los servicios)
Languages/           páginas de lenguajes y versiones
Utilities/           página Utilidades y su catálogo
Tools/               página común de herramienta (ToolPage, ToolInfo, ReceiverOptions) y Mail/, Dumps/, Logs/
  Terminal/          herramienta Terminal: hosts, SFTP, fragmentos, reenvíos y consolas locales
Git/                 herramienta Git
  Model/             GitTool, GitRepository y estado
  Changes/ History/ Branches/ Conflicts/ Organize/ Sync/ Problems/ More/  pestañas y hojas
  Hosting/           GitHub y Bitbucket: cliente HTTP, cuentas (GitHostingVault), pull requests, clonar
  MenuBar/           sección Git del panel de la barra de menús
  Migration/         «Traer mis repositorios…»
  Dictionary/        diccionario de comandos
  Pieces/            diff, árbol de cambios, grafo de commits (lo que es de Git)
Database/            herramienta Cliente de bases de datos
SSHKeys/             claves SSH de la base y su sesión (SSHKeyring): Ajustes › Claves SSH, túneles y Terminal
Vault/               herramienta Bóveda (todo lo de la Bóveda vive aquí)
AWS/                 herramienta AWS (lista y cabecera de Shared/Cloud/)
Google/              herramienta Google Cloud (archivos GCP*; lista y cabecera de Shared/Cloud/)
Skills/              herramienta Skills (archivos Skill*: lista, detalle, editor, IA, salud, hojas de confirmación)
Settings/            Ajustes (General, Apariencia, Red, Herramientas, Claves SSH, Avanzado); LocalTrust (resolver y CA),
                     ConfigurationBackup («Mi entorno»: exportar y restaurar)
Shared/              componentes, Symbols, Typography, Brand, StackFolders, TechCatalog
  Code/              editor de código, resaltado de sintaxis, ícono de tipo de archivo, barras temáticas
  Cloud/             lista de cuentas, fila y cabecera de tarjeta comunes a AWS y Google Cloud
QA/                  ganchos de QA (QAHooks, QALayout) y servidores falsos; todo tras #if DEBUG
Resources/           es.lproj (Localizable.strings y .stringsdict), GitDictionary.json, logo, ícono de barra
Logos/               logos de productos con sus licencias
FileIcons/           íconos de tipo de archivo (SVG con licencia) y map.json
```

Pruebas de la app: `native/Tests/ButakeStackTests/` (un archivo por área: `VaultTests`, `GitToolTests`,
`ProjectRenameTests`, `SidebarTests`…).

## Dónde vive cada herramienta

| Herramienta | Motor | App | Pruebas |
|---|---|---|---|
| Git | `engine/src/git/` | `Git/` | `git/tests/`, `Git*Tests.swift`, `CompositeGitTests.swift` |
| Terminal | `engine/src/ssh/` | `Tools/Terminal/`, `SSHKeys/` (base) | `ssh/*`, `SSHTests.swift`, `LocalConsoleTests.swift`, `KeysAndCloudTests.swift` |
| Cliente de bases de datos | `engine/src/db/` | `Database/` | `db/*` en línea, `DatabaseTests.swift`, `DatabaseInterfaceTests.swift` |
| Bóveda | — | `Vault/` | `Vault*Tests.swift` |
| Correo | `web/tools/mail.rs`, `daemon/mod.rs` | `Tools/Mail/`, `Tools/ReceiverOptions.swift` | `web/tools/mail.rs`, `ReceiverToolsTests.swift` |
| Dumps | `web/tools/dumps.rs`, `daemon/mod.rs` | `Tools/Dumps/`, `Tools/ReceiverOptions.swift` | `web/tools/dumps.rs`, `ReceiverToolsTests.swift` |
| AWS | `engine/src/aws/`, `core/cli_tool.rs` | `AWS/`, `Shared/Cloud/` | `aws/*`, `engine/tests/aws.rs`, `AWSTests.swift` |
| Google Cloud | `engine/src/gcp/`, `core/cli_tool.rs` | `Google/`, `Shared/Cloud/` | `gcp/mod.rs`, `GCPTests.swift`, `KeysAndCloudTests.swift` |
| Skills | `engine/src/skills/` | `Skills/` | `skills/tests/`, `SkillsTests.swift` |
| Registros (base) | `daemon/logs.rs`, `daemon/redact.rs` | `Tools/Logs/` | `daemon/*`, `ToolsTests.swift` |

## Scripts

```
scripts/test-native.sh     pruebas del motor, de PHP (Python) y de la app, y el candado de interfaz
scripts/build-native.sh    compila y firma build/native.noindex/Stack.app (BUILD= número de compilación)
scripts/lint-ui.sh         candado de interfaz contra scripts/lint-ui.baseline (con lint-ui-blocks.py)
scripts/order-strings.py   ordena Localizable.strings por área sin cambiar claves ni valores (--write)
scripts/signing.sh         elige la identidad de firma estable
scripts/package-dmg.sh     DMG firmado y notarizado (dmg-background.swift dibuja el fondo)
scripts/install-native.sh  compila e instala en /Applications (no usar en QA)
scripts/run-native.sh      compila y abre la app compilada
scripts/php/               fabricación y empaquetado de PHP propio, con pruebas en php/tests
```
