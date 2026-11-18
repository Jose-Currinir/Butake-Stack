# Arquitectura

```
SwiftUI/AppKit
  ├── stdin/stdout JSON → butake-stack (CLI de petición/respuesta)
  │                         └── socket Unix → daemon, para operaciones de supervisión
  └── stdout JSONL ← butake-stack watch-status ← eventos y estados del daemon
                                                  └── Caddy, DNS, PHP-FPM, servicios y proyectos
```

El binario Rust `butake-stack` incluye el CLI y el daemon. El CLI lee un JSON
por stdin y responde con `{ok, value | error}`. El daemon vive en el LaunchAgent
`cl.butake.stack.daemon`: supervisa procesos, captura logs, reinicia con espera
progresiva y apaga sus hijos en orden. Cerrar la interfaz deja los proyectos y servicios
supervisados en ejecución. El cliente de bases cierra sus sesiones y túneles al
salir de la app.

Puertos 53, 80 y 443: macOS no deja a un proceso normal escuchar en `127.0.0.1` bajo el 1024.
El plist del LaunchAgent declara `Sockets` (`http`, `https`, `dns`, `dns-tcp`); launchd los abre
y el daemon los recibe con `launch_activate_socket`. Caddy hereda 80/443 como descriptores y el
DNS corre dentro del daemon. Así Stack corre sin root; solo `/etc/resolver/<tld>` (que apunta
los dominios locales a `127.0.0.1:53`) necesita una vez la autorización de administrador.

Socket: `run/daemon.sock` de la carpeta de datos (permisos 0600),
protocolo JSON por líneas: `{"id", "method", "params"}` → `{"id", "ok", "value"|"error",
"protocol"}`, y eventos `process.state`, `stack.changed` y `stream.lagged`. `protocol`
(`daemon::PROTOCOL`, hoy 1) sube cuando cambia la forma de una petición o una respuesta: el daemon
es un LaunchAgent que sobrevive a la app, y si contesta con otro número (o sin él, como 0.1.3 y
anteriores) el CLI le pide `shutdown` y arranca el actual, con `launchctl kickstart` si el agente
de sesión sirve esa misma carpeta de datos o como hijo si no; si aun así no calza, responde
`daemon_outdated`. El puente envía un estado inicial, vuelve a consultar ante eventos y se reconecta si el daemon sale. El estado de servicios auxiliares se actualiza también cada 15 s desde la misma sesión.

Las consultas de estado y registros acceden a un índice publicado al aplicar la configuración.
Pueden leer el estado de un proceso durante su apagado. Las órdenes de control se ejecutan en
serie. Cada vista de Registros o Dumps abre una suscripción que se cierra al salir de la vista.

## Qué incluye

- **Proyectos**: carpeta, dominios `.test`, HTTPS, tipo (Laravel, PHP, estático, Node.js, proxy,
  Astro, EmDash, Next.js, KMP, Django, FastAPI, Rust), versión de cada lenguaje, procesos
  supervisados, entornos `.env` y registros. Carpetas y proyectos de varias partes
  (`groups.json`). Todo en [proyectos.md](proyectos.md).
- **Lenguajes**: PHP (compilación propia), Node.js, Python, Java, Rust y Swift, con varias
  versiones a la vez. Cada proyecto guarda la suya en el archivo estándar del lenguaje.
- **Servicios**: MySQL, PostgreSQL, MongoDB, Redis, Valkey, Meilisearch, Typesense y RustFS,
  agrupados por tipo (bases de datos, caché y colas, tiempo real, búsqueda, almacenamiento), más
  Caddy, el DNS interno y un PHP-FPM por versión en uso.
- **Herramientas** ([herramientas.md](herramientas.md)): Git, Terminal, Cliente de bases de datos,
  Bóveda, Correo, Dumps, AWS y Google Cloud, además de Registros (base).
- **Utilidades** (ver más abajo): asistentes de IA, AWS CLI, Cloudflare, Git y GitHub CLI,
  instalados desde la fuente de cada fabricante y verificados.
- **Compartir**, **Xdebug** y carpetas vigiladas (ver más abajo).
- **Actualizaciones** verificadas y **asistente de configuración** para preparar un Mac nuevo.

## Interfaz de macOS

La ventana principal usa `NavigationSplitView`, con barra lateral (Inicio, Proyectos,
Herramientas, Nube y Componentes) y barra de herramientas nativas. Los ajustes usan `Form` agrupado.
La app vive en la barra de menús: su panel enciende servicios y abre proyectos, y la ventana
completa se abre a pedido. El estado de Stack tiene una sola fuente: el indicador de la barra
inferior (el mismo en el panel), que abre el popover «Estado» con el supervisor, lo que corre y
quién ocupa los puertos 53, 80 y 443. La norma de diseño está en `docs/estandar-ui.md`.

El tema Butake tiene fondos neutros y superficies opacas diferenciadas en claro y oscuro. En
macOS 26 o posterior, el buscador, la paleta de comandos y las notificaciones flotantes usan
Liquid Glass; en macOS 15 usan material del sistema. Con Reducir transparencia usan un fondo
opaco.

## Datos en disco

```
~/Library/Application Support/Stack/
  stack.json              configuración global (versiones, puertos, TLD, Correo, Dumps, Xdebug)
  projects/<id>.json      un archivo por proyecto
  groups.json             carpetas y proyectos de varias partes
  watched.json            carpetas vigiladas
  envs/<id>.json          entornos de un proyecto, sin valores secretos
  data/<servicio>/        datadir de cada servicio; data/caddy/ guarda la CA local
  config/                 archivos generados (Caddyfile JSON, php-fpm pools, my.cnf, redis.conf)
                          y datos de herramientas: plugins.json, connections.json, ssh/, git/
  logs/<proceso>.log      rotación por tamaño; env-audit.log (auditoría de Entornos)
  run/                    sockets, pid y estado de túneles y reenvíos
  runtimes/php/<versión>/ binarios estáticos de PHP + manifest.json
  runtimes/<pieza>/<versión>/  lenguajes, servicios y Caddy descargados, cada uno con su manifest.json
  cache/ downloads/       catálogos remotos guardados y descargas en curso
  tunnels/                dirección fija: credenciales (0600) y addresses.json
  mail/                   mensajes de Correo (0600)
  db-history/ db-tabs/    historial y pestañas del editor SQL
  vault/                  Bóveda: índice y archivos cifrados (ver boveda-formato.md)
  aws-backups/ aws-runs/  respaldos de AWS CLI; procesos de AWS CLI en curso
  gcp-runs/               procesos de gcloud en curso
  utilities/<id>.json     lo que Stack colocó de cada utilidad
  migration.json          diario del traslado desde la carpeta del nombre anterior, si lo hubo
  renames.json            renombres de proyectos con pasos pendientes para la app (sin valores)
```

Qué guarda cada herramienta y dónde: [herramientas.md](herramientas.md).

Una instalación anterior al nombre «Stack» sigue usando `Application Support/Butake Stack` hasta
que el usuario mueve los datos (Ajustes › Avanzado o `butake-stack migrate-data`; ver
`docs/operations.md`). El motor y la app resuelven la carpeta con la misma regla
(`Store::resolve`, `Folder.resolveData`); `BUTAKE_STACK_HOME` la sustituye en pruebas y QA. Dónde van
los proyectos nuevos y qué pasa si una carpeta desaparece: [proyectos.md](proyectos.md#modelo).

Los archivos generados se reescriben desde el modelo; no se editan a mano.

## Proyectos

Modelo de proyecto, tipos, detección, carpetas, proyectos de varias partes, entornos, marcadores y
direcciones: [proyectos.md](proyectos.md). `program` se resuelve contra el runtime del proyecto (`php`
→ binario de la versión elegida), nunca por `PATH` del shell; los procesos corren con `cwd = path` y el
entorno mínimo más `PATH` con los runtimes del proyecto.

### Renombrar y mover un proyecto

«Renombrar…» cambia el título y el identificador; «Cambiar carpeta…» apunta el proyecto a otra
carpeta existente, sin mover ni copiar archivos (menú del proyecto y Proyecto en la barra de menús).
El motor lo hace con `renameProject` y `moveProject` (`engine/src/web/projects/rename.rs`): valida antes de
tocar nada, aplica todos los cambios de archivos en un solo paso (`core/journal.rs`) y, si uno falla,
deja cada archivo como estaba. Un proyecto encendido se detiene antes y se vuelve a iniciar al
terminar (no se rechaza): sus procesos no pueden escribir registros mientras estos cambian de nombre.
Compartirlo (dirección temporal o fija) se apaga con él y el usuario lo vuelve a encender.

```sh
# id nuevo libre y válido; "domain": true cambia el primer dominio a <newId>.<tld>; "name" opcional
echo '{"method":"renameProject","id":"tienda","newId":"tienda-web","name":"Tienda web","domain":true}' | butake-stack
# carpeta existente que no sea de otro proyecto
echo '{"method":"moveProject","id":"tienda-web","path":"/Users/ana/codigo/tienda-web"}' | butake-stack
# lo que queda para la app, y cómo se marca hecho
echo '{"method":"pendingRenames"}' | butake-stack
echo '{"method":"renameStepDone","from":"tienda","to":"tienda-web","step":"app"}' | butake-stack
```

`renameProject` responde `project`, `restarted`, `places` (lo que cambió) y `pending`: los pasos que
solo la app puede hacer, guardados en `renames.json` hasta que los completa — `keychain` (si el
proyecto tiene entornos y la app no los movió ya: `"keychainMoved": true`), `vault` (si hay Bóveda)
y `app` (preferencias de este Mac). La app los completa al abrirse, en cada actualización de la lista
(cada 15 s) y, `vault`, al desbloquear la Bóveda. Desde la app el Llavero va primero: se copian sus
ítems al id nuevo y se verifican; si el Llavero no responde, no se renombra; si el motor rechaza, se
quitan las copias; solo con el renombre hecho se borran los ítems viejos. Un enlace
`butakestack://project/rename?id=<id>&newId=<nuevo>` abre la hoja ya rellenada para confirmar; nunca
renombra solo. `moveProject` responde `project`, `restarted`, `places` y `envReapply` (el `.env` del
entorno activo no está en la carpeta nueva: la app pide aplicarlo otra vez).

Errores: `invalid_new_id`, `same_id`, `id_in_use` (otro proyecto, o entornos o un túnel que quedaron
con ese id), `domain_in_use`, `unknown_project`, `same_folder`, `folder_in_use`, `invalid_path`,
`target_exists`.

| Lugar | Al renombrar | Al cambiar carpeta |
|---|---|---|
| `projects/<id>.json` | Se escribe con el id nuevo (título y dominio si se piden) y se borra el viejo | `path` nuevo |
| `groups.json` (carpetas y proyectos de varias partes) | El id se reemplaza en su lugar: el orden de arranque no cambia | Un repositorio agregado igual a la carpeta vieja pasa a la nueva |
| `envs/<id>.json` | Se renombra | Sin cambio; `envReapply` si falta el `.env` |
| `{port:<id>}` y `{public:<id>}` en `env` y argumentos de todos los proyectos | Se reescriben al id nuevo | — |
| Los mismos marcadores en entornos de otros proyectos y su lista `outdated` | Se reescriben | — |
| `tunnels/addresses.json` y credenciales `tunnels/<id>.json` | Pasan al id nuevo; `<id>.yml` se borra y se escribe al compartir | — |
| Túnel en Cloudflare (`stack-<id>`) | Conserva su nombre e id: la dirección fija sigue igual | — |
| `logs/<id>.<proceso>.log` (y rotaciones), `python-<id>.log`, `task-<id>.log`, `env-<id>.log` | Se renombran | — |
| `logs/env-audit.log` | Sus líneas pasan al id nuevo, más una «renombrar» | — |
| `run/pids/<id>.<proceso>`, procesos del supervisor y lo que se comparte | Se van al detenerlo; vuelven con el id nuevo | Igual |
| Caddy y certificados locales | Se regeneran al recargar; el dominio solo cambia si se pide | Raíz nueva al recargar |
| Enlace de Google Cloud | Viaja en el registro | — |
| Bases declaradas (`databases`) | Sin cambio (son nombres de bases, no del proyecto) | — |
| `config/git/repositories.json` | — | El reciente de la carpeta vieja pasa a la nueva |
| Llavero `cl.butake.stack.env`, cuentas `<id>/<entorno>` (y antiguas `<id>/<entorno>/<CLAVE>`) | App: copiar sin decodificar, verificar, borrar las viejas | — |
| Bóveda: apps enlazadas al proyecto | App: al desbloquear (`group:<id>` es de la carpeta y no cambia) | — |
| Favoritos del panel, `git.head.<id>`, página abierta | App | — |
| `renames.json` | Entrada con los pasos pendientes | — |

No se cubre: un `{port:<id>}` escrito dentro del valor de un secreto (está en el Llavero y el motor
no lo ve: al activar ese entorno, Stack avisa que nombra un proyecto que no existe y el usuario lo
corrige en Entornos); el «último repositorio abierto»
de la herramienta Git, si era la carpeta vieja, deja de proponerse.

## Lenguajes, servicios y Caddy

PHP es **estático y propio**: binarios `php` y `php-fpm` compilados con static-php-cli, con las
extensiones dentro, en `runtimes/php/<versión>/` (ver `docs/php-runtimes.md`). Todo lo demás
también son binarios por versión en `runtimes/<pieza>/<versión>/`, sin gestores de paquetes
externos:

| Pieza | Origen | Nota |
|---|---|---|
| PHP | static-php-cli, compilado y empaquetado por Butake | un `php-fpm` por versión en uso, socket propio, `pm = ondemand` |
| Composer | `composer.phar` con hash, dentro del runtime de PHP | `program: composer` → `php composer.phar` |
| Node.js | tarball oficial de nodejs.org, verificado con `SHASUMS256.txt` | |
| Python | compilaciones CPython independientes, verificadas con la suma de su publicación | `.venv` por proyecto |
| Java | JDK de Temurin, verificado | |
| Rust, Swift | instaladores oficiales (`rustup`, `swiftly`) en la carpeta personal | |
| Caddy | binario oficial con hash fijo | configuración JSON generada, administración por socket Unix, `tls internal` |
| MySQL | tarball oficial de Oracle, firma de Apple | datadir propio |
| MongoDB, Meilisearch, Typesense, RustFS | binarios oficiales, verificados | un datadir por servicio |
| PostgreSQL, Redis, Valkey | fuente oficial verificada, compilada por Butake | configuración propia |

PostgreSQL se compila con sus extensiones estándar (`contrib`: citext, pgcrypto, uuid-ossp,
pg_trgm, unaccent, hstore, btree_gin, btree_gist, pg_stat_statements, sslinfo y las demás) y con
OpenSSL para `pgcrypto` y TLS. Stack no construye ni descarga otra OpenSSL reutilizable (la de PHP
va enlazada dentro de su binario; Redis y Valkey se compilan sin TLS), así que usa el código
oficial de la versión LTS fijada en `engine/src/runtimes/utilities/catalog/mod.rs` con su SHA-256, compilado
estático dentro del runtime de PostgreSQL, sin programas ni bibliotecas compartidas. Una versión
instalada sin extensiones se detecta al listar y ofrece «Reinstalar con extensiones», que compila
aparte y reemplaza la carpeta solo cuando la nueva está completa; los datos no se tocan.

Los puertos y las versiones son configurables y se leen de la fuente oficial; ninguna versión
va fija en el código. La app muestra el estado de cada pieza (instalada, versión, ruta) y el
botón «Instalar».

## Utilidades

La página «Utilidades» instala, actualiza y quita programas de terceros que no son de un lenguaje
(`engine/src/runtimes/utilities/`, con `devtools/`). Nada se descarga sin la confirmación que dice
versión, fuente, verificación y destino; nada descargado se ejecuta para instalarlo (ni scripts, ni
`installer`, ni `sudo`); la firma y la notarización se comprueban con `codesign`, `spctl` y `pkgutil`
(`core/signature.rs`) contra el equipo de Developer ID fijado en el código. Si algo no verifica, no se
coloca nada.

| Utilidad | Fuente | Verificación | Dónde queda |
|---|---|---|---|
| Codex | Release más reciente de `openai/codex` en GitHub, `codex-package-<arch>-apple-darwin.tar.gz` | SHA-256 de `codex-package_SHA256SUMS` (esa lista, contra el resumen de GitHub) igual al resumen de GitHub del paquete; cada programa firmado por OpenAI (`2DC432GLL2`); notarización | `~/.codex/packages/standalone`, enlaces `codex` y `codex-code-mode-host` en `~/.local/bin` (como su instalador oficial) |
| Claude Code | `downloads.claude.ai/claude-code-releases`, canal `latest`, `manifest.json` y binario por plataforma | SHA-256 del manifiesto; firma de Anthropic (`Q6L2SF6YDW`); notarización | `~/.local/share/claude/versions/<versión>`, enlace `~/.local/bin/claude` |
| Claude Desktop | Canal de actualizaciones de la app (`downloads.claude.ai/releases/darwin/universal/RELEASES.json`), `.zip` | Sin suma publicada: firma de Anthropic en toda la app (`codesign --deep --strict`), notarización (`spctl`), identificador y versión del bundle | `~/Applications/Claude.app` (no pide administrador y la app se actualiza sola) |
| ChatGPT | Canal de actualizaciones de la app (`persistent.oaistatic.com/codex-app-prod/appcast.xml`, el que nombra la propia app), `ChatGPT-darwin-arm64-<versión>.zip`; solo Apple silicon | Sin suma publicada (la firma EdDSA del canal no se comprueba): firma de OpenAI (`2DC432GLL2`) en toda la app, notarización, identificador (`com.openai.codex`) y versión del bundle. El botón de la página de descarga entrega un instalador que habría que ejecutar; no se usa | `~/Applications/ChatGPT.app` |
| AWS CLI v2 | `awscli.amazonaws.com`: versión de `v2/version.txt` y `AWSCLIV2-<versión>.pkg` | Firma del paquete de AWS (`94KV3E626L`) y notarización; firma de `aws` y `aws_completer`; el paquete se expande con `pkgutil` sin ejecutar sus scripts | `~/.local/share/aws-cli`, enlaces `aws` y `aws_completer` en `~/.local/bin` |
| Git | Código oficial de la última versión estable en `www.kernel.org/pub/software/scm/git` (`git-<versión>.tar.gz`); Git no publica binarios para Mac | SHA-256 de `sha256sums.asc` (la firma OpenPGP de esa lista no se comprueba: macOS no trae la herramienta). Se compila con `make` (argumentos separados, entorno mínimo, compilador de Apple; sin gettext, Perl, Python, Tcl/Tk, Rust ni expat; HTTPS con el libcurl del sistema) solo si están las herramientas de línea de comandos y, con Xcode, su licencia aceptada (`xcode_license_pending` si falta: se pregunta al compilador antes de descargar nada, igual que al compilar Redis, Valkey, PostgreSQL y sus extensiones) | `~/.local/share/butake-stack/git/<versión>` (con su `etc/gitconfig`: contraseñas en el Llavero, como el Git de Apple), enlace `~/.local/bin/git` |
| GitHub CLI, cloudflared, Wrangler | Ver «Herramientas y piezas locales» | Lista SHA-256, firma de Cloudflare o integridad de npm | `~/.local/bin` |

El Git de Apple (de las herramientas de línea de comandos o de Xcode) se muestra como «De Apple»: se
localiza con `xcode-select -p` y se ejecuta el de esa carpeta, nunca `/usr/bin/git`, que sin las
herramientas solo ofrece instalarlas. No impide instalar el de Stack, que en la terminal va antes.

Stack guarda en `utilities/<id>.json` (en su almacén) las rutas que colocó; solo esas se quitan, y
los datos y ajustes de cada utilidad (`~/.codex`, `~/.claude`, `~/.aws`) se conservan. Una copia
instalada por otra vía se muestra con su ruta y versión, pero Stack no la reemplaza ni la quita
(`installed_elsewhere`, `not_managed`). Con `BUTAKE_DEVTOOLS_HOME` (pruebas y QA) todo, incluida la
carpeta de aplicaciones, queda dentro de esa carpeta temporal y no se mira el resto del Mac.

### Límite de consultas de GitHub

Sin autenticar, la API de GitHub admite 60 consultas por hora y red. `core/github.rs` la usa lo
mínimo: la etiqueta más reciente sale de la redirección de `github.com/<repo>/releases/latest` y
los archivos de `releases/download/<etiqueta>/<archivo>` (ninguno cuenta); lo que solo dice la API
(el resumen SHA-256 de un archivo, las listas de versiones) se guarda en `cache/github-*.json`
una hora y después se vuelve a pedir con `If-None-Match` (un 304 no cuenta). El catálogo de
Python se lee del `SHA256SUMS` de la versión. Si GitHub limita la red, se usa la copia guardada;
sin copia, el error es `source_rate_limited` con los minutos que faltan, distinto de
`download_offline` (sin conexión) y `download_failed` (el servidor respondió con error). Una
fuente que no responde deja en la fila de su utilidad «No se pudo consultar la última versión» con
«Reintentar», o la versión conocida de antes con su antigüedad. Nunca se envía un token del
usuario; subir el límite con uno sería una opción explícita y desactivada por defecto (no existe
hoy).

## Herramienta AWS

Perfiles de AWS CLI (`engine/src/aws/`): [herramientas/aws.md](herramientas/aws.md).

## Herramienta Google Cloud

Cuentas de gcloud y enlace de cada proyecto (`engine/src/gcp/`):
[herramientas/google-cloud.md](herramientas/google-cloud.md).

## Herramienta Git

Motor de Butake Git dentro de Stack (`engine/src/git/`): [herramientas/git.md](herramientas/git.md).
Dos rasgos de arquitectura: el motor de Stack es síncrono y el de Git asíncrono (tokio), así que el
despacho de la herramienta lo ejecuta con `block_in_place`; y las mutaciones se serializan en la app
(un proceso del motor por pedido). Los respaldos de reescritura conservan el prefijo
`refs/butake/backup/` de Butake Git, de modo que los ya creados siguen sirviendo para «Deshacer».

## Dominios, DNS y HTTPS

- DNS interno en Rust dentro del daemon (`127.0.0.1:53` vía launchd; 1053 en QA, UDP+TCP) que responde `A 127.0.0.1` (AAAA vacío a propósito, para que el navegador use IPv4)
  para cualquier nombre bajo los TLD configurados.
- `/etc/resolver/<tld>` con `nameserver 127.0.0.1` y el puerto del DNS propio. La app lo detecta
  (listo, falta o apunta a otro DNS) y lo crea o repara con confirmación: el archivo se prepara en
  el almacén y se copia con el diálogo de administrador de macOS (`osascript … with administrator
  privileges`, valores solo como `argv` con `quoted form of`). Nunca se guarda la contraseña.
- `.local` se desaconseja en la UI: choca con mDNS/Bonjour y da latencias de 5 s. Se
  recomienda `.test`.
- Caddy recibe 80/443 en `127.0.0.1` como descriptores heredados de launchd (macOS solo
  permite puertos <1024 sin root en `0.0.0.0`, que expondría los proyectos a la red) y emite
  certificados con su CA local (`skip_install_trust`: Caddy no toca el llavero). «Confiar» agrega
  la raíz (`data/caddy/pki/authorities/local/root.crt`) al llavero de inicio de sesión, confiable
  solo para SSL (`security add-trusted-cert` sin `-d`: macOS pide la contraseña en su propio
  diálogo); el estado se comprueba con `security verify-cert -p ssl`. Con un almacén aislado
  (`BUTAKE_STACK_HOME`) ambas acciones se simulan dentro de él.
- Por proyecto: `php_fastcgi unix//…/run/php-<serie>.sock` con `root = path/docroot`, o
  `reverse_proxy` para proyectos de Node.js, de proxy y los de servidor de desarrollo.

## Herramientas y piezas locales

- **Herramientas activables** (`engine/src/app/plugins.rs`, `config/plugins.json`): la base se separa
  de las herramientas; sus métodos responden `plugin_disabled` si están apagadas. Catálogo y reglas en
  [herramientas.md](herramientas.md); Correo y Dumps corren dentro del daemon
  ([herramientas/correo.md](herramientas/correo.md), [herramientas/dumps.md](herramientas/dumps.md)).
- **Compartir**: un túnel rápido de `cloudflared` por proyecto, supervisado por el daemon
  (`share.<id>`), hacia `http://127.0.0.1:<http>` con el `Host` del proyecto. Solo en memoria: se
  detiene al apagar el proyecto o reiniciar el daemon, nunca se reanuda solo.
- **Dirección fija** (`web/net/tunnels.rs`, `daemon/public.rs`): un túnel con nombre por proyecto
  (`stack-<id>`) en un dominio del usuario, por defecto `<id>-test.<zona>` (el certificado
  universal de Cloudflare cubre un solo nivel; dos niveles necesitan uno avanzado). Conectar es
  `cloudflared tunnel login`, supervisado (`cloudflare.login`) y cancelable; Stack solo comprueba
  que existe `~/.cloudflared/cert.pem`, nunca lo lee ni lo copia, y desconectar no lo borra. Crear
  hace `tunnel create` y `tunnel route dns` (si el registro falla, el túnel se borra); las
  credenciales quedan en `tunnels/<id>.json` (0600) y la dirección en `tunnels/addresses.json`,
  fuera de la exportación del entorno. Compartir corre `tunnel run` con un archivo generado
  (`tunnels/<id>.yml`: entrada a `http://127.0.0.1:<http>` con `httpHostHeader` del dominio
  `.test`, y 404 para lo demás) como proceso `public.<id>`, en su grupo y sin reinicio solo.
  Compartir vive en memoria del daemon: la dirección sigue configurada, pero reiniciar Stack o
  detener el proyecto deja de compartir. Quitar hace `tunnel delete` y borra las credenciales;
  el registro DNS queda (no hay forma segura de borrarlo desde aquí) y la app lo dice. Los fallos
  de `cloudflared` llegan como códigos fijos; su salida nunca sale del motor.
- **Xdebug**: por serie de PHP en `stack.json`; `php.ini` lo carga solo si el runtime trae
  `xdebug.so` verificado, y solo se reinicia el PHP-FPM de esa serie.
- **Carpetas vigiladas** (`watched.json`): ofrecen los proyectos nuevos; nunca se agregan sin preguntar.

## Seguridad

- Durante la detección, Stack obtiene solo los nombres de variables y los puertos numéricos
  permitidos del `.env`. Stack genera el archivo únicamente al activar de forma explícita un
  entorno gestionado, o al reescribirlo desde su almacén cuando cambia el puerto de un proyecto
  que nombra con `{port:<id>}` (sin secretos; ver más abajo).
- Lectura de valores de un `.env`: el motor solo lee los valores del `.env` que escribió Stack,
  y solo para pasarlos a los procesos (la regla exacta y sus límites están en `AGENTS.md`,
  «Secretos»). Un `.env` escrito a mano nunca se lee; para saber si un archivo es de Stack se
  lee solo su primera línea.
- Entorno activo en los procesos: con «Pasar el entorno activo a los procesos» (Entornos,
  activado por defecto), el supervisor lee el `.env` del proyecto en cada inicio de un proceso,
  solo si lo escribió Stack (su primera línea lo dice), es un archivo regular (nunca un enlace)
  de 1 MiB o menos, y lo pone en el ambiente del proceso. Precedencia: las variables de Stack (`HOME`, `PATH`, `PHPRC`,
  `JAVA_HOME`, `VIRTUAL_ENV`…) y el `env` del proyecto con sus marcadores ganan sobre el entorno
  activo, que gana sobre los valores por omisión (`LANG`). Las `DYLD_*` no pasan. Los valores no
  quedan en la especificación del proceso ni en registros: el registro solo dice cuántas variables.
- `{port:<id>}` en el `env` del proyecto y en los valores de un entorno se reemplaza por el puerto
  del otro proyecto (al lanzar y al escribir el `.env`); un proyecto inexistente es un error al
  guardar y deja el proceso sin iniciar. Las referencias se calculan al vuelo (`web::envs::port_dependents`).
  Cuando cambia el `upstream` de un proyecto o se elimina, el motor vuelve a escribir el `.env` de
  los proyectos cuyo entorno activo lo nombra si no tiene secretos y el archivo es de Stack
  (auditado como «actualizar»); si tiene secretos (el motor no los tiene) o el proyecto ya no
  existe, marca el entorno como desactualizado (`outdated`). La app lo vuelve a aplicar con el
  Llavero (salvo Producción, que pide confirmación) y ofrece reiniciar los procesos en marcha;
  nunca los reinicia sin preguntar. Entornos avisa del `.env` desactualizado y de los proyectos
  nombrados que ya no existen. El `env` del proyecto se resuelve en cada lanzamiento: si cambia,
  el supervisor reinicia el proceso como con cualquier cambio de su especificación y su registro
  dice por qué.
- `{public:<id>}` se reemplaza por `https://<dirección fija>` del proyecto nombrado, en los mismos
  lugares que `{port:<id>}`. Un proyecto inexistente es un error al guardar; uno sin dirección fija
  deja la variable fuera del `.env` y del ambiente del proceso (un argumento bloquea el proceso), y
  Entornos la muestra pendiente (`publicPending`). Al configurar, cambiar o quitar la dirección,
  los `.env` que la nombran se escriben de nuevo o quedan desactualizados, como con un puerto.
- Correo muestra texto, código HTML, cabeceras y fuente en controles nativos.
- Sin shell: `Command::new(binario).args(...)`. Los comandos de proyecto se guardan como
  `program` + `args`; la interfaz no ofrece texto libre de shell.
- Todo escucha en `127.0.0.1`/`::1`, nunca en `0.0.0.0`.
- Socket del daemon 0600; el daemon rechaza peticiones de otro UID (`getpeereid`).
- Las contraseñas de los servicios propios se guardan en el Llavero; la app las copia al
  portapapeles a pedido. Las claves que el propio motor necesita para administrar un servicio
  sin la app (clave maestra de Meilisearch y Typesense, secreto de RustFS, superusuario de
  PostgreSQL) viven en `config/<servicio>/` con permisos 600; el motor nunca las muestra,
  registra ni devuelve.
- PostgreSQL: un clúster nuevo se inicializa con `scram-sha-256` para TCP (127.0.0.1 y ::1) y
  para el socket local (`unix_socket_permissions = 0700`); el superusuario `postgres` recibe una
  clave aleatoria que pasa a `initdb` por un archivo privado que se borra al terminar. Un clúster
  existente no cambia al actualizar: si su `pg_hba.conf` tiene `trust`, el cliente de bases
  ofrece «Exigir contraseña…» (pone clave al superusuario, reescribe `pg_hba.conf`, guarda el
  anterior como `pg_hba.conf.stack-trust` y recarga sin reiniciar; comprueba que sin clave ya no
  entra) y «Volver a entrar sin contraseña…» para deshacerlo (`web/services/postgres_auth.rs`).
- Logs locales con rotación; no se envía telemetría.

## Principios y buenas prácticas

Capas, de adentro hacia afuera; cada una solo conoce a la de abajo:

| Capa | Archivo | Responsabilidad |
|---|---|---|
| Modelo | `engine/src/core/model.rs` | Tipos y validación (ids, dominios, puertos, rutas canonicalizadas, programas permitidos) |
| Almacenamiento | `core/store.rs`, `core/json.rs`, `core/fsutil.rs` | Resolución de la carpeta de datos, JSON con escritura atómica (temporal + `rename` + `fsync`), permisos 0600/0700, sin enlaces simbólicos |
| Catálogo | `runtimes/` | Versiones desde la fuente oficial, descarga solo con confirmación, verificación por checksum o firma de Apple, instalación atómica |
| Configuración generada | `web/services/web_server.rs`, `web/services/engines.rs` | `php-fpm.conf`, `Caddyfile`, `my.cnf`, `redis.conf` desde el modelo; nunca a mano |
| Supervisor | `daemon/supervisor.rs`, `daemon/redact.rs` | Procesos sin shell, grupo propio, backoff, logs con rotación y valores ocultos (no líneas), recarga selectiva, apagado con espera por proceso |
| Daemon | `daemon/mod.rs`, `web/net/listeners.rs`, `web/net/dns.rs` | Socket Unix 0600 con UID verificado, sockets de launchd, DNS interno |
| CLI JSON | `main.rs` | Contrato estable `{method} → {ok, value \| error}` sin reflejar datos del usuario en errores |
| Interfaz | `native/` | Estado observable en el actor principal y vistas; la app es solo la cara: cerrarla no baja Stack |

- **Sin privilegios**: nada corre como root. Los puertos 53/80/443 los abre launchd para el
  agente de sesión; todo escucha en `127.0.0.1`.
- **Cadena de suministro**: ninguna versión fija en el código. Cada pieza se verifica con la
  suma o la firma que publica su fuente oficial (por ejemplo, Node.js con `SHASUMS256.txt`,
  Caddy con su archivo de sumas y MySQL con la firma de Apple de Oracle).
- **Datos**: un datadir por servicio en `data/`. La importación usa clones APFS (instantánea, sin
  duplicar espacio) y nunca modifica el origen. MySQL se actualiza en el lugar al cambiar de versión.
- **Cambios sin interrupciones**: la recarga compara cada proceso con su definición anterior y
  solo reinicia lo que cambió; el orden de arranque es servicios → php-fpm → Caddy → proyectos.
- **Apagado limpio**: SIGTERM al grupo y espera propia (MySQL 120 s, Redis 60 s, resto 10 s)
  antes de SIGKILL.
- **Protocolos modernos**: HTTP/2 y HTTP/3 (QUIC) con TLS 1.3 en los proyectos con HTTPS.
- **App de barra de menús**: el panel enciende servicios y abre proyectos; la ventana completa
  se abre a pedido.
- **Entorno de procesos**: variables mínimas, `HOME` real, `PATH` solo con los runtimes del proyecto,
  `LANG` válido en macOS.

### Estructura del código

Árbol comentado de `engine/src/` y `native/Sources/ButakeStack/`, y dónde vive cada herramienta:
[mapa-del-repositorio.md](mapa-del-repositorio.md).

### Métodos del motor sin llamada desde la app

Revisión de R-1 (2026-11-14). Un método que la app no llama se conecta si falta su función, se
conserva si lo usa otro llamador (anotado junto al método) o se quita con sus pruebas.

| Método | Decisión | Quién lo usa o por qué |
|---|---|---|
| `setMail`, `setDumps` | Conectado | «Opciones…» de Correo y de Dumps (puerto; en Correo, días y máximo de mensajes) |
| `generatePhpIni` | Conservado | `scripts/php/build_php.py` (fabricación de PHP propio) |
| `gitRun`, `gitPrepare` | Conservado | Línea de comandos: un comando de consola revisado con la misma política que `git-console` |
| `gitRebaseCandidates`, `gitValidateRebase` | Conservado | El plan del rebase interactivo que usan `git-console` y `git-write-plan` |
| `gitSetMainProtection` | Conservado | Única forma de cambiar la protección de la rama principal (la app solo la lee); las pruebas preparan estados con él |
| `clearDumps`, `sharePublic`, `cloudflareLogin` | Conservado | Del daemon: solo los pide el propio motor (`request_sync`) |
| `gitCloneName`, `gitPullRequestUrl`, `gitFiles`, `gitBranchDiff`, `gitPreviewFile`, `gitSaveFile` | Quitado | Sin llamador; la app arma el nombre del clon y las páginas del proveedor, y el visor de archivos es de solo lectura |
| `portDependents` | Quitado | Sin llamador; los proyectos afectados siguen llegando en las respuestas de guardar y eliminar |
| `installSwiftly` | Quitado (R-2) | Sin llamador; swiftly se instala como utilidad de desarrollo (`devtools`) |

## Git de los proyectos, enlaces y diseño compartido

- **Git de solo lectura.** El motor (`engine/src/web/projects/git.rs`) llama a `/usr/bin/git` con argumentos (sin
  shell) y `GIT_OPTIONAL_LOCKS=0`. Métodos: `gitStatus` (rama, HEAD, cambios, ↑/↓ por proyecto),
  `worktrees`, `addWorktreeSite` (sirve un worktree como `<rama>.<proyecto>.test`, apagado y sin
  procesos), `branchChanges` (qué cambió entre dos commits: Composer, npm, migraciones) y
  `siteTask` (`composer install`, `npm install`, `artisan migrate` con el PHP y el Node.js de Stack).
- **Esquemas de URL** (`App/StackStore+Links.swift`). Un enlace solo muestra: nunca conecta, importa,
  renombra ni desbloquea. Una herramienta desactivada abre Ajustes › Herramientas con su fila resaltada.

  | Enlace | Abre |
  |---|---|
  | `butakestack://setup` (alias `welcome`) | Asistente de configuración |
  | `butakestack://site/<id>` | El proyecto |
  | `butakestack://open?path=<carpeta>` | El proyecto de esa carpeta, o propone agregarla |
  | `butakestack://project/rename?id=<id>&newId=<nuevo>` | La hoja de renombrar, rellenada |
  | `butakestack://tool/<id>` | La herramienta (`tool/logs?source=…` o `?origin=…`: Registros filtrado) |
  | `butakestack://git?path=<repositorio>` | Ese repositorio en la herramienta Git |
  | `butakestack://vault`, `vault/import?path=<carpeta>` | La Bóveda; la vista previa de importación ([herramientas/boveda.md](herramientas/boveda.md#enlaces)) |
  | `butakestack://ssh/<host>`, `db/<conexión>` | Ese host o esa conexión, seleccionados |
  | `butakestack://service/<categoría>` | Componentes › Servicios en esa categoría |
  | `general`, `plugins`, `service/web` | Alias: Ajustes › General, Herramientas o Red |
  | `service/mail`, `service/dumps`, `service/logs` | Alias: la herramienta |

  Stack ya no abre la app Butake Git: con la herramienta apagada, un proyecto no ofrece nada de Git
  más allá de las filas de la base.
- **Butake Design.** `Theme`, `ThemeStore`, `TextScale` y `Font.ui…` viven en el paquete
  [Butake-Design](https://github.com/Jose-Currinir/Butake-Design), compartido con Butake Git.

## Instalación, requisitos y actualizaciones

- **Asistente de configuración.** Al iniciar, si falta PHP, Caddy o el agente de sesión, se abre
  la hoja de requisitos. PHP se descarga del release `runtimes` de este repositorio (`catalog.json`
  con la SHA-256 de cada compilación; `phpCatalog` / `downloadPhp`). El catálogo viene firmado: el
  motor baja también `catalog.json.sig` (ECDSA P-256 sobre SHA-256, en DER) y lo verifica con
  Security.framework contra la clave pública que lleva dentro (`CATALOG_PUBLIC_KEY` en
  `engine/src/runtimes/languages/php.rs`); sin firma válida (`catalog_unsigned`,
  `catalog_signature_invalid`) no se usa el catálogo ni se instala nada. Después se verifica la
  SHA-256 del paquete y, ya extraído en una carpeta de preparación, la de cada archivo del
  manifiesto, y solo entonces se mueve a `runtimes/php/<versión>/`. Un paquete local elegido por el
  usuario sigue verificándose contra el `catalog.json` de su carpeta, sin firma. Caddy y Node.js de sus
  catálogos oficiales, y las herramientas de Apple con `xcode-select --install`. Todo pide
  confirmación.
- **Actualizaciones.** El actualizador consulta `releases/latest`, descarga `Butake-Stack.zip`
  (la app comprimida con `ditto`, con el ticket de notarización adjunto), verifica la SHA-256
  publicada, la firma Developer ID de Butake SpA y Gatekeeper, reemplaza la app y reinicia el
  agente (`launchctl kickstart`). No monta el DMG: macOS trata una imagen montada como un volumen
  extraíble y leerla exige un permiso de privacidad que Stack nunca pide. Las versiones sin `.zip`
  (0.1.1 y anteriores) se instalan desde su DMG. El release `runtimes` no es «latest».

## Proyectos sin servidor, avisos y servicios en uso (P-42)

- **Clase «sin servidor»** (`kind: "unserved"`): apps, bibliotecas, herramientas y plantillas.
  Sin dominio (los que tenía se guardan para volver a otra clase), sin `upstream`, nunca
  encendido (`setSiteEnabled` responde `project_not_served`) y fuera del `Caddyfile`. Sus
  procesos son comandos («Comprobar», «Compilar») que el supervisor solo arranca a pedido, una
  vez y sin reinicio. Se detecta al agregar un repositorio sin `public/`, `index.*` ni servidor
  reconocible; `listProjects` añade `technology` (no se guarda). Programas permitidos: los de
  siempre más `swift`, `xcodebuild` y `make` (de `/usr/bin`).
- **Avisos** (`projectAttention`, `web/projects/attention.rs`): se calculan al leer, nunca se guardan —
  servicio apagado o sin instalar, puerto fijo de otro proyecto, sitio estático que sirve su
  `.git`, programa o guion inexistente, guion que solo reenvía a otro (los argumentos de Stack
  no llegan), Node.js fuera de `.nvmrc`/`engines.node`. `applyProjectFix` recalcula y aplica la
  corrección ofrecida; solo cambia el registro de Stack, nunca los archivos del proyecto.
- **Servicios en uso** (`web/projects/service_use.rs`): `setEngine` escribe bajo el candado del almacén;
  apagar un servicio que usan proyectos encendidos exige `confirmed` (si no, `service_in_use`
  con sus nombres). Encender un proyecto enciende sus servicios instalados y responde
  `servicesStarted`. Cada cambio queda en `logs/services.log` (0600) con quién lo pidió (`app`,
  `project:<id>` o `cli`).
- **Puertos fijos** (`Project::fixed_ports`): `upstream`, un número en `PORT`/`SERVER_PORT`/…
  y el que sigue a `--port`/`-p`. Guardar uno que otro proyecto declara responde `port_in_use`
  con el puerto y el nombre del otro; un registro anterior con conflicto sigue encendiéndose y
  su página lo avisa.
- **Versiones en uso** (`runtimes/languages/usage.rs`): `removePhp`, `removePython` y `removeTool` (Node,
  JDK) rechazan la versión global (`runtime_global`) o la que usa un proyecto
  (`runtime_in_use`). `versions.mysql` de `stack.json` se descarta al leer y desaparece al
  guardar.
