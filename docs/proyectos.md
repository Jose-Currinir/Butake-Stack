# Proyectos

Qué es un proyecto en Stack, cómo se agrupa, cómo se renombra o se mueve, y cómo recibe su entorno,
sus direcciones y su enlace de Google Cloud. El detalle de daemon, Caddy, DNS y seguridad está en
[architecture.md](architecture.md).

## Modelo

Un archivo por proyecto en `projects/<id>.json` de la carpeta de datos (`core/model.rs`, `Project`).
El motor rechaza campos desconocidos.

```json
{
  "id": "tienda",
  "name": "Tienda",
  "path": "/Users/ana/Stack/Projects/Web/tienda",
  "domains": ["tienda.test"],
  "https": true,
  "kind": "laravel",
  "runtime": { "php": "8.4", "node": "24" },
  "docroot": "public",
  "services": ["mysql", "redis"],
  "databases": ["tienda", "tienda_test"],
  "processes": [
    { "name": "cola", "program": "php", "args": ["artisan", "queue:work"], "autostart": true },
    { "name": "vite", "program": "npm", "args": ["run", "dev"], "autostart": true }
  ],
  "enabled": false,
  "upstream": 41873,
  "env": { "API_URL": "https://{public:tienda-api}", "WS_PORT": "{port:tienda-ws}" },
  "gcp": { "account": "ana@example.com", "project": "tienda-dev" }
}
```

| Campo | Qué es |
|---|---|
| `id` | `[a-z0-9-]`, único; nombra registros, entornos, túneles y marcadores |
| `name` | Título visible |
| `path` | Carpeta del proyecto (canonicalizada); la configuración nunca se escribe ahí |
| `domains`, `https` | Dominios bajo los TLD locales (`.test` recomendado) |
| `kind` | Tipo (ver abajo) |
| `runtime` | Versión de cada lenguaje; también se escribe en el archivo estándar del lenguaje (`.nvmrc`, `.java-version`, `.python-version`…) |
| `docroot` | Raíz pública para PHP y estáticos |
| `services`, `databases` | Servicios que usa y bases declaradas |
| `processes` | Procesos supervisados: `program` + `args`, nunca una línea de shell. `program` se resuelve contra el runtime del proyecto, no contra el `PATH` |
| `enabled` | Encendido: servido y con sus procesos en marcha. Un proyecto nuevo empieza apagado |
| `upstream` | Puerto propio que Caddy reenvía, asignado libre por Stack |
| `env` | Variables no secretas para sus procesos, con marcadores (ver Entornos) |
| `gcp` | Enlace de Google Cloud, opcional |

Proyectos nuevos van por defecto a `~/Stack/Projects`, en la subcarpeta `App`, `Service` o `Web` que
sugiere su tipo (`ProjectPlace`); se cambia en Ajustes › Avanzado. Los existentes nunca se mueven
solos. Un proyecto cuya carpeta desapareció queda con `missing: true`, apagado, hasta que
`relocateProject` lo apunta a su carpeta nueva.

## Tipos de proyecto

`kind` (`ProjectKind`): `laravel`, `php`, `static`, `node`, `proxy`, `astro`, `emdash`, `next`, `kmp`,
`django`, `fastapi`, `rust`. Los PHP se sirven con `php_fastcgi`; los demás, por `reverse_proxy` al
puerto `upstream` de su propio servidor.

El asistente de nuevo proyecto (`web/projects/scaffold/mod.rs`) usa el generador oficial de cada uno (Laravel con
sus starter kits, Astro, EmDash, Next.js, Vite, Django, FastAPI, Rust). Un paquete de Swift o una app
de React Native se registran como proyecto sin servidor (`unserved`), con sus comprobaciones; una
herramienta de línea de comandos de Rust crea la carpeta pero no registra un proyecto.

Detección al agregar una carpeta existente (`web/projects/detect.rs`): Laravel por `artisan` y
`laravel/framework`; Reverb, procesos de Artisan desde `config/supervisor/*.conf` y Vite si hay script
`dev`. Del `.env` solo se leen nombres de variables y puertos numéricos.

## Servicios y bases de un proyecto

Un proyecto declara los servicios que usa (`services`) y sus bases (`databases`). Desde Entornos se
puede crear una base y sus cuentas en el PostgreSQL o el MySQL de Stack (`createDatabase`,
`rotateDatabasePassword`; `web/services/databases.rs`); las contraseñas van al Llavero como secretos del
entorno.

## Carpetas y proyectos de varias partes

`groups.json` (`core/store.rs`, `SiteGroup`) guarda las carpetas de la barra lateral: `id`, `name` y
`sites` (sus proyectos, en orden). Una carpeta marcada como proyecto (`"kind": "project"`) es un
**proyecto de varias partes**: cada parte es un proyecto con su repositorio («Web», «App y servidor»).
Campos que solo se escriben cuando dicen algo, de modo que un `groups.json` anterior se lee y se guarda
igual:

| Campo | Qué es |
|---|---|
| `kind` | `"project"`; ausente (o desconocido) es carpeta |
| `repositories` | Repositorios que no son un proyecto (carpeta superior), hasta 50 |
| `ordered` | Iniciar las partes en orden: cada una espera a que la anterior responda |
| `gcp` | Cuenta y proyecto de Google Cloud que heredan las partes sin enlace propio |

- Menú de la carpeta: «Convertir en proyecto» y «Volver a carpeta» (no pierde nada).
- En Inicio, su encabezado lleva el símbolo de proyecto de varias partes y un botón «Abrir el
  proyecto»; en la paleta de comandos (⇧⌘O) aparece como «Proyecto de varias partes» y abre su página.
- Página del proyecto (ruta `composite:<id>`): partes con «Iniciar todo» y «Detener todo» (la última
  primero), orden de arranque, dependencias detectadas (`{port:<id>}`, `{public:<id>}`), «Git del
  proyecto» (todas sus partes y repositorios; necesita la herramienta Git), apps de la Bóveda enlazadas
  al proyecto (`group:<id>`, que heredan sus partes) y su enlace de Google Cloud.
- La dirección fija sigue siendo de cada parte. Confirmar y subir en Git siguen siendo de un
  repositorio a la vez.

## Renombrar y mover

«Renombrar…» cambia el título y el identificador (y el primer dominio, si se pide); «Cambiar
carpeta…» apunta el proyecto a otra carpeta existente sin mover archivos. El motor lo hace con
`renameProject` y `moveProject` (`web/projects/rename.rs`) en un solo paso con reversión (`core/journal.rs`); un
proyecto encendido se detiene antes y se vuelve a iniciar al terminar. Lo que solo la app puede hacer
(Llavero de Entornos, Bóveda, preferencias) queda en `renames.json` hasta que la app lo completa.

```sh
echo '{"method":"renameProject","id":"tienda","newId":"tienda-web","name":"Tienda web","domain":true}' | butake-stack
echo '{"method":"moveProject","id":"tienda-web","path":"/Users/ana/codigo/tienda-web"}' | butake-stack
```

Tabla completa de lo que cambia, errores y pasos pendientes:
[architecture.md](architecture.md#renombrar-y-mover-un-proyecto). Regla de cumplimiento: R22.

## Entornos

Un entorno es un conjunto `.env` del proyecto (Local, Pruebas, Staging, Producción…), en
`envs/<id>.json` sin valores secretos; los secretos van al Llavero, un ítem por proyecto y entorno
(`cl.butake.stack.env`, cuenta `<id>/<entorno>`; `Projects/Environments/EnvSecrets.swift`). Activar uno
escribe el `.env` en la carpeta del proyecto, con la cabecera de Stack en la primera línea. Producción
pide autenticación y confirmación. Toda acción queda en `logs/env-audit.log`, sin valores. Reglas
completas: `.compliance/docs/21719-gestor-entornos-requisitos.md` (R1 a R12).

Métodos: `envList`, `envSave`, `envMergeSecrets`, `envDelete`, `envActivate`, `envExport`, `envAudit`,
`envAuditLog`, `envClassify` (`web/projects/envs/mod.rs`).

Con «Pasar el entorno activo a los procesos» (activado por defecto), el supervisor pasa los valores del
`.env` escrito por Stack a cada proceso al iniciarlo (ver [architecture.md](architecture.md#seguridad)).

### Marcadores

En `env` del proyecto y en los valores de un entorno:

| Marcador | Se reemplaza por |
|---|---|
| `{port}`, `{domain}` | El puerto y el dominio del propio proyecto, al iniciar un proceso |
| `{port:<id>}` | El puerto del proyecto `<id>` |
| `{public:<id>}` | `https://<dirección fija>` del proyecto `<id>` |

Un proyecto inexistente es un error al guardar. Uno sin dirección fija deja la variable fuera del
`.env` y del proceso, y Entornos la muestra pendiente (`publicPending`). Cuando cambia el puerto o la
dirección de un proyecto nombrado, el motor reescribe los `.env` que lo usan si no tienen secretos; si
los tienen, los marca desactualizados (`outdated`) y la app los vuelve a aplicar con el Llavero. Las
referencias se calculan al vuelo (`web::envs::port_dependents`).

## Direcciones públicas

Ambas son de la base y se apagan con el proyecto o al reiniciar el daemon: compartir nunca se reanuda
solo y siempre se confirma.

- **Dirección temporal** (`shareSite`): un túnel rápido de `cloudflared` hacia el proyecto, con una
  dirección que cambia cada vez. Necesita `cloudflared` (Utilidades).
- **Dirección fija** (`web/net/tunnels.rs`, `daemon/public.rs`): un túnel con nombre por proyecto
  (`stack-<id>`) en un dominio del usuario, por defecto `<id>-test.<zona>`. Con ella funcionan el
  ingreso con proveedores que exigen orígenes autorizados y los enlaces absolutos (`{public:<id>}`).
  Métodos: `tunnelStatus`, `tunnelConnect`, `tunnelConfigure`, `tunnelChange`, `tunnelRemove`,
  `tunnelShare`. Credenciales en `tunnels/<id>.json` (0600) y direcciones en `tunnels/addresses.json`,
  fuera de la exportación. Quitar borra el túnel y sus credenciales; el registro DNS queda y la app lo
  dice. Detalle en [architecture.md](architecture.md#herramientas-y-piezas-locales). Regla: R16.

## Enlace de Google Cloud

Campo `gcp` del proyecto, o del proyecto de varias partes para las partes sin enlace propio. Sus
procesos y «Abrir consola aquí» reciben `CLOUDSDK_CORE_ACCOUNT`, `CLOUDSDK_CORE_PROJECT` y
`GOOGLE_CLOUD_PROJECT`; una de ellas escrita a mano en `env` gana. Se edita con la herramienta Google
Cloud: [herramientas/google-cloud.md](herramientas/google-cloud.md).

## Enlaces

- `butakestack://site/<id>`: abre el proyecto.
- `butakestack://open?path=<carpeta>`: abre el proyecto de esa carpeta o propone agregarla.
- `butakestack://project/rename?id=<id>&newId=<nuevo>`: abre la hoja de renombrar ya rellenada; nunca
  renombra sola.
