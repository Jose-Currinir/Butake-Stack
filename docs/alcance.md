# Alcance: todo lo necesario para trabajar, en una app

Decisión del titular (2026-11-11): Butake Stack centraliza el desarrollo local. Incluye también lo que
hoy hacen **DBngin, TablePlus, Expose y Tinkerwell**, y **Debugbar sólo en local** para proyectos
Laravel. Todos los motores y runtimes se instalan desde la app, sin Homebrew ni Docker.

## Módulos

| Módulo | Reemplaza | Qué hace | Fase |
|---|---|---|---|
| **Sitios** | — | Proyectos con carpeta, dominio `.test`, HTTPS, tipo y versión; procesos supervisados | 1 |
| **Runtimes** | nvm, Homebrew | PHP estático 8.2–8.5 propio, Node, Composer; instalar, actualizar y limpiar versiones sin uso | 1 |
| **Motores** | DBngin, brew, Docker | MySQL 8.0/8.4, MariaDB, PostgreSQL, Redis/Valkey; luego Meilisearch y MinIO. Varias versiones e instancias, cada una con su puerto, datadir y logs; encendido por proyecto | 1 (MySQL, Redis, Postgres) · 2 (resto) |
| **Base de datos** | TablePlus | Cliente nativo: conexiones, árbol de bases/tablas, grilla con filtros y edición, editor SQL con resaltado y autocompletado, estructura e índices, importar/exportar dump y CSV | 2 (lectura y SQL) · 3 (edición y estructura) |
| **Compartir** | Expose | Publicar un sitio local con URL pública temporal por Cloudflare Tunnel; se apaga solo; reescribe el host para Laravel (`APP_URL` temporal) | 2 |
| **Consola PHP** | Tinkerwell | Editor multilínea que ejecuta código en el contexto del proyecto (`artisan tinker` con su PHP), con resultados formateados, historial y fragmentos guardados | 2 |
| **Debugbar local** | Laravel Debugbar | Barra de depuración en las páginas del proyecto **sólo en local**, sin tocar `composer.json` ni el repo | 3 |
| **Correo** | HELO | SMTP local + bandeja | 2 |
| **Logs** | Pail | Visor unificado | 2 |

## Cómo se instalan los motores (sin brew)

Igual que PHP: binarios propios por versión en `runtimes/<motor>/<versión>/` con `manifest.json`
(versión, hash SHA-256, origen). La app descarga o compila sólo lo que un proyecto pide.

| Motor | Origen previsto | Nota |
|---|---|---|
| PHP | static-php-cli, compilado localmente | T-03a |
| MySQL 8.0 / 8.4 | tarball oficial de Oracle para macOS arm64, hash verificado | mismo motor que DBngin y producción |
| MariaDB | compilado o paquete oficial | sólo si un proyecto lo pide |
| PostgreSQL 16/17 | binarios oficiales/compilados | para Butake-Gestion (Kotlin) |
| Redis / Valkey | compilado (código pequeño, sin dependencias) | |
| Caddy | binario oficial de GitHub con hash | |
| Node | tarball oficial de nodejs.org con hash | reemplaza nvm |
| cloudflared | binario oficial | para Compartir |

Toda descarga es explícita (botón con nombre, origen y tamaño), verificada por hash y en su
propia carpeta. Nunca automática.

## Debugbar sólo en local: cómo, sin tocar el proyecto

1. Interruptor «Debugbar» por proyecto (sólo tipo Laravel).
2. Al activarlo, el daemon lanza un **pool php-fpm aparte para ese proyecto** con
   `auto_prepend_file` apuntando a `bridge/bootstrap.php` de Butake Stack. Los demás proyectos y
   el pool normal no cambian.
3. El bridge comprueba `APP_ENV=local` y que el request venga de 127.0.0.1; si no, no hace nada.
   Registra un service provider propio (sin Composer del proyecto) que escucha consultas,
   vistas, eventos, jobs, caché, HTTP salientes, logs, excepciones, tiempo y memoria.
4. Muestra los datos en una **barra inyectada al final del HTML** (sólo respuestas HTML) y en
   la ventana de la app. Ajuste por proyecto: barra en página, sólo app, o ambas.
5. Datos sensibles: parámetros SQL, cookies y encabezados de autorización ocultos por defecto;
   RUT, correos y teléfonos enmascarados.
6. Al apagarlo, se detiene el pool aparte y el proyecto vuelve a su pool normal. El repo nunca
   recibe archivos ni dependencias.

Alternativa disponible: si el proyecto ya tiene `barryvdh/laravel-debugbar` en `require-dev`,
la app sólo lo enciende/apaga con la variable de entorno del pool (`DEBUGBAR_ENABLED`).

## Límites honestos

- El cliente de bases es el módulo más grande; empieza por lo que más se usa (ver tablas,
  filtrar, correr SQL, exportar) y crece. No se anuncia paridad con TablePlus.
- Conexiones a bases **remotas** (RDS, producción) en sólo lectura por defecto, con aviso visible
  y confirmación para escribir; contraseñas en el Llavero.
- Compartir expone el sitio a internet: siempre con confirmación, URL temporal y aviso en la
  barra de menú mientras esté activo.
- La consola PHP ejecuta código real contra la base configurada en el `.env`; avisa si
  `DB_HOST` no es local.
