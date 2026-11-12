# Arquitectura

```
SwiftUI/AppKit (native/)  ──JSON por socket Unix──▶  butake-stackd (daemon Rust, LaunchAgent)
        │                                                  │ supervisa procesos hijos
        └──JSON por stdin/stdout──▶ butake-stack (CLI)     ├─ caddy        (HTTP/HTTPS, *.test)
                                                           ├─ dns interno  (dentro del daemon, 127.0.0.1:53)
                                                           ├─ php-fpm 8.x  (un pool por versión)
                                                           ├─ mysqld 8.0   (datadir propio)
                                                           ├─ redis-server
                                                           └─ procesos de proyecto (reverb, colas,
                                                              scheduler, vite…)
```

Un solo binario Rust, `butake-stack`, con dos modos:

- **CLI de petición/respuesta** (igual que el motor de Butake Git): lee un JSON por stdin y
  responde `{ok, value | error}`. Sirve para lecturas y para la terminal.
- **`butake-stack daemon`**: proceso de larga vida registrado como LaunchAgent
  `cl.butake.stack.daemon`. Dueño de todos los procesos hijos: los arranca, reinicia con
  backoff, captura logs y los detiene en orden al salir. La app sólo es la cara; cerrarla no
  baja el stack.

Puertos 53, 80 y 443: macOS no deja a un proceso normal escuchar en `127.0.0.1` bajo el 1024.
El plist del LaunchAgent declara `Sockets` (`http`, `https`, `dns`, `dns-tcp`); launchd los abre
y el daemon los recibe con `launch_activate_socket`. Caddy hereda 80/443 como descriptores y el
DNS corre dentro del daemon. Así el stack no necesita root ni tocar `/etc/resolver/test`, que ya
apunta a `127.0.0.1:53`. Fuera de launchd (QA) se usan los puertos de `stack.json`.

Socket: `~/Library/Application Support/Butake Stack/run/daemon.sock` (permisos 0600),
protocolo JSON por líneas: `{"id", "method", "params"}` → `{"id", "ok", "value"|"error"}`, y
eventos `{"event": "process.state" | "log" …}` para la UI en vivo.

## Datos en disco

```
~/Library/Application Support/Butake Stack/
  stack.json              servicios globales (versiones, puertos, TLD)
  projects/<id>.json      un archivo por proyecto
  data/mysql-8.0/         datadir de MySQL
  data/redis/             dump/AOF de Redis
  config/                 archivos generados (Caddyfile JSON, php-fpm pools, my.cnf, redis.conf)
  logs/<servicio>.log     rotación por tamaño
  run/                    sockets y pid
  ca/                     CA local de Caddy
  runtimes/php/<versión>/ binarios estáticos de PHP + manifest.json
```

Los archivos generados se reescriben desde el modelo; no se editan a mano.

## Modelo de proyecto

```json
{
  "id": "gestion",
  "name": "Gestión",
  "path": "/Users/…/Gestion",
  "domains": ["gestion.test"],
  "https": true,
  "kind": "laravel",            // laravel | php | node | static | proxy
  "runtime": { "php": "8.2", "node": "24" },
  "docroot": "public",
  "services": ["mysql", "redis"],
  "databases": ["firesoft_panel", "firesoft_panel_fixture"],
  "processes": [
    { "name": "reverb",    "program": "php", "args": ["artisan","reverb:start","--port=8082"], "autostart": true },
    { "name": "cola",      "program": "php", "args": ["artisan","queue:work","redis","--queue=realtime,default","--sleep=1","--tries=3","--timeout=90"], "autostart": true },
    { "name": "scheduler", "program": "php", "args": ["artisan","schedule:work"], "autostart": false },
    { "name": "vite",      "program": "npm", "args": ["run","dev"], "autostart": true }
  ]
}
```

`program` se resuelve contra el runtime del proyecto (`php` → binario de la versión elegida),
nunca por `PATH` del shell. Los procesos corren con `cwd = path` y el entorno mínimo más
`PATH` con los runtimes del proyecto.

### Detección al crear un proyecto

Al elegir la carpeta, el motor propone (el usuario confirma o cambia en la UI):

- Laravel si hay `artisan` + `laravel/framework` en `composer.json`; PHP mínimo desde
  `require.php`; `docroot = public`.
- Reverb si `laravel/reverb` está en `composer.json`; puerto desde `REVERB_SERVER_PORT` del `.env`.
- Colas desde `config/supervisor/*.conf` (`queue:work …`), o una cola `default` si no hay.
- Vite si `package.json` tiene script `dev`.
- MySQL/Redis según `DB_CONNECTION`, `REDIS_HOST`, `CACHE_STORE`, `QUEUE_CONNECTION`.
- Del `.env` sólo se leen nombres de clave, puertos, host y nombre de base; nunca contraseñas.

## Runtimes

PHP es **estático y propio** (decisión 2026-11-11): binarios `php` y `php-fpm` compilados con
static-php-cli, con todas las extensiones dentro, en `runtimes/php/<versión>/` (ver
`docs/php-runtimes.md`). Objetivo para todos los motores: binarios propios por
versión, sin Homebrew (ver `docs/alcance.md`). En la fase 1 MySQL y Redis
siguen en DBngin y `brew services`; T-08 los reemplaza:

| Pieza | Origen | Nota |
|---|---|---|
| PHP 8.2 (8.5 en T-08b) | static-php-cli, compilado y empaquetado por Butake | un `php-fpm` por versión en uso, socket propio, `pm = ondemand` |
| Composer | `composer.phar` con hash, dentro del runtime PHP | `program: composer` → `php composer.phar` |
| Node | tarball oficial de nodejs.org, verificado con `SHASUMS256.txt` | para Vite; sin nvm |
| Web | binario oficial de Caddy con hash fijo | config JSON generada, admin por socket Unix, `tls internal` |
| MySQL | fase 1: DBngin; T-08: tarball oficial de Oracle | datadir propio, puerto 3306 |
| Redis | fase 1: `brew services`; T-08: compilado | config propia |

La app muestra el estado de cada runtime (instalado, versión, ruta) y el botón «Instalar».

## Dominios, DNS y HTTPS

- DNS interno en Rust dentro del daemon (`127.0.0.1:53` vía launchd; 1053 en QA, UDP+TCP) que responde `A 127.0.0.1` / `AAAA ::1`
  para cualquier nombre bajo los TLD configurados.
- `/etc/resolver/test` con `nameserver 127.0.0.1` (puerto 53): el DNS propio atiende ahí, así que
  el archivo no se modifica.
- `.local` se desaconseja en la UI: choca con mDNS/Bonjour y da latencias de 5 s. Se
  recomienda `.test`.
- Caddy recibe 80/443 en `127.0.0.1` como descriptores heredados de launchd (macOS sólo
  permite puertos <1024 sin root en `0.0.0.0`, que expondría los sitios a la red) y emite
  certificados con su CA local; «Confiar certificado» la agrega al llavero del sistema
  con confirmación.
- Por proyecto: `php_fastcgi unix//…/run/php-8.2.sock` con `root = path/docroot`, o
  `reverse_proxy` para proyectos `node`/`proxy`. Reverb se publica en `ws://localhost:8082`
  como hoy; opcional `wss://gestion.test/app` por proxy.

## UI

Ventana principal con barra lateral y menú en la barra superior (estado verde/ámbar/rojo).

- **Proyectos**: lista con dominio y estado; detalle con pestañas *General* (carpeta,
  dominio, HTTPS, tipo, versión de PHP/Node), *Servicios* (MySQL, Redis y bases),
  *Procesos* (añadir/quitar, autoarranque, iniciar/detener/reiniciar), *Logs* (por proceso,
  en vivo, con filtro) y *Entorno* (claves esperadas por el `.env`, sin valores).
- **Servicios**: MySQL, Redis, Caddy, DNS, PHP-FPM por versión: estado, puerto, iniciar/detener,
  logs, abrir en TablePlus.
- **Runtimes**: versiones instaladas y por instalar.
- **Servir los sitios .test** (en Servicios): quién ocupa 53/80/443 y activar el agente de
  sesión, que recibe esos puertos de macOS.

## Seguridad

- Sin shell: `Command::new(binario).args(...)`. Comandos de proyecto se guardan como
  `program` + `args`; la UI no ofrece texto libre de shell.
- Todo escucha en `127.0.0.1`/`::1`, nunca `0.0.0.0` (Reverb hoy usa `0.0.0.0`; el preset
  lo deja en `127.0.0.1`).
- Socket del daemon 0600; el daemon rechaza peticiones de otro UID (`getpeereid`).
- Contraseña root de MySQL generada y guardada en el Llavero; la app la copia al portapapeles
  a pedido.
- Logs locales con rotación; no se envía telemetría.

## Principios y buenas prácticas

Capas, de adentro hacia afuera; cada una sólo conoce a la de abajo:

| Capa | Archivo | Responsabilidad |
|---|---|---|
| Modelo | `engine/src/model.rs` | Tipos y validación (ids, dominios, puertos, rutas canonicalizadas, programas permitidos) |
| Almacenamiento | `store.rs` | JSON con escritura atómica (temporal + `rename` + `fsync`), permisos 0600/0700, sin enlaces simbólicos |
| Catálogo | `tools.rs`, `runtimes.rs` | Versiones desde la fuente oficial, descarga sólo con confirmación, verificación por checksum o firma de Apple, instalación atómica |
| Configuración generada | `services.rs` | `php-fpm.conf`, `Caddyfile`, `my.cnf`, `redis.conf` desde el modelo; nunca a mano |
| Supervisor | `supervisor.rs` | Procesos sin shell, grupo propio, backoff, logs con rotación y redacción, recarga selectiva, apagado con espera por proceso |
| Daemon | `daemon.rs`, `listeners.rs`, `dns.rs` | Socket Unix 0600 con UID verificado, sockets de launchd, DNS interno |
| CLI JSON | `main.rs` | Contrato estable `{method} → {ok, value \| error}` sin reflejar datos del usuario en errores |
| UI | `native/` | `StackStore` (`@Observable`, `@MainActor`) y vistas; la app es sólo la cara: cerrarla no baja el stack |

- **Sin privilegios**: nada corre como root. Los puertos 53/80/443 los abre launchd para el
  agente de sesión; todo escucha en `127.0.0.1`.
- **Cadena de suministro**: ninguna versión fija en el código. Node (SHASUMS256), Caddy
  (SHA-512), Redis (redis-hashes, compilado localmente) y MySQL (firma de Apple con el Team ID
  de Oracle). Se omiten piezas que un servidor local no carga.
- **Datos**: un datadir por motor en `data/`. La importación usa clones APFS (instantánea, sin
  duplicar espacio) y nunca modifica el origen. MySQL se actualiza en el lugar al cambiar de versión.
- **Cambios sin interrupciones**: la recarga compara cada proceso con su definición anterior y
  sólo reinicia lo que cambió; el orden de arranque es motores → php-fpm → Caddy → sitios.
- **Apagado limpio**: SIGTERM al grupo y espera propia (MySQL 120 s, Redis 60 s, resto 10 s)
  antes de SIGKILL.
- **Protocolos modernos**: HTTP/2 y HTTP/3 (QUIC) con TLS 1.3 en los sitios con HTTPS.
- **App de barra de menús**: sin ícono en el Dock (`LSUIElement`) ni ventana al abrir; el panel
  enciende motores y abre sitios; la ventana completa se abre a pedido.
- **Entorno de procesos**: variables mínimas, `HOME` real, `PATH` sólo con los runtimes del sitio,
  `LANG` válido en macOS.

## Mejoras pendientes

- La UI consulta el estado cada 3 s; pasar a la suscripción de eventos que el daemon ya emite.
- Apagar motores sin uso tras unos minutos y encenderlos a pedido.
- Contraseña de `root` de MySQL para bases nuevas guardada en el Llavero (hoy la base nueva
  queda sin clave, sólo en 127.0.0.1; los datos importados conservan sus usuarios).

## Enlace con Butake Git y diseño compartido

- **Git de solo lectura.** El motor (`engine/src/git.rs`) llama a `/usr/bin/git` con argumentos (sin
  shell) y `GIT_OPTIONAL_LOCKS=0`. Métodos: `gitStatus` (rama, HEAD, cambios, ↑/↓ por sitio),
  `worktrees`, `addWorktreeSite` (sirve un worktree como `<rama>.<sitio>.test`, apagado y sin
  procesos), `branchChanges` (qué cambió entre dos commits: Composer, npm, migraciones) y
  `siteTask` (`composer install`, `npm install`, `artisan migrate` con el PHP/Node del stack).
- **Esquemas de URL.** Stack atiende `butakestack://site/<id>` y `butakestack://open?path=`; Butake Git
  atiende `butakegit://open?path=`. Butake Git lee los registros de sitios de Stack (sólo `id` y
  `path`) para ofrecer «Abrir en Butake Stack» o «Agregar a Butake Stack».
- **Butake Design.** `Theme`, `ThemeStore`, `TextScale` y `Font.ui…` viven en el paquete
  [Butake-Design](https://github.com/Jose-Currinir/Butake-Design), compartido por las dos apps
  (`.package(url:…, from: "1.0.0")`).

## Instalación, requisitos y actualizaciones

- **Preparar Butake Stack.** Al iniciar, si falta PHP, Caddy o el agente de sesión, se abre la hoja
  de requisitos. PHP se descarga del release `runtimes` de este repositorio (`catalog.json` con la
  SHA-256 de cada compilación; `phpCatalog` / `downloadPhp`), Caddy y Node de sus catálogos
  oficiales, y las herramientas de Apple con `xcode-select --install`. Todo pide confirmación.
- **Actualizaciones.** `UpdateService` consulta `releases/latest`, descarga el DMG, verifica la
  SHA-256 publicada, la firma Developer ID de Butake SpA (equipo 9MJ82YJXM2) y Gatekeeper, reemplaza
  la app y reinicia el agente (`launchctl kickstart`). El release `runtimes` no es «latest».
