# Herramientas: una base fija y herramientas que se activan

Todo lo que se puede activar o desactivar es una herramienta (`engine/src/app/plugins.rs`), sin un
segundo concepto. Hay una **base** que siempre está y **herramientas** que vienen dentro de la app
firmada y se activan en Ajustes › Herramientas. Desactivar nunca borra datos; «Eliminar datos…» lo hace
aparte, con confirmación (la Bóveda, solo desde la propia Bóveda). Ninguna depende de aplicaciones de
terceros.

## Herramientas

| Herramienta | Id | Documento | Empieza |
|---|---|---|---|
| Git | `git` | [herramientas/git.md](herramientas/git.md) | Apagada |
| Terminal | `ssh-terminal` | [herramientas/terminal.md](herramientas/terminal.md) | Apagada |
| Cliente de bases de datos | `database-client` | [herramientas/bases-de-datos.md](herramientas/bases-de-datos.md) | Encendida |
| Bóveda | `vault` | [herramientas/boveda.md](herramientas/boveda.md) | Encendida |
| Correo | `mail` | [herramientas/correo.md](herramientas/correo.md) | Apagada |
| Dumps | `dumps` | [herramientas/dumps.md](herramientas/dumps.md) | Apagada |
| AWS | `aws` | [herramientas/aws.md](herramientas/aws.md) | Apagada |
| Google Cloud | `gcp` | [herramientas/google-cloud.md](herramientas/google-cloud.md) | Apagada |

Registros es de la base, pero se muestra con las herramientas:
[herramientas/registros.md](herramientas/registros.md).

Para agregar una nueva: [como-agregar-una-herramienta.md](como-agregar-una-herramienta.md).

## Barra lateral

La barra lateral y la paleta de comandos muestran solo las herramientas activas, en tres bloques bajo
Inicio y Proyectos (`App/SidebarLayout.swift`):

- **Herramientas**: lo que se usa. Git, Terminal, Cliente de bases de datos, Bóveda, Correo, Dumps y
  Registros, en ese orden; una herramienta que la lista no conoce va antes de Registros.
- **Nube**: las cuentas de cada proveedor (AWS, Google Cloud); sin ninguna activa no aparece.
- **Componentes**: lo que se instala en el Mac (Servicios, Lenguajes y Utilidades), cada uno con sus
  categorías en la columna de contenido.

## Qué es base y qué es herramienta

| Base (siempre) | Herramienta (se elige) |
|---|---|
| Proyectos, proyectos de varias partes, dominios `.test`, HTTPS, agente de sesión | Git |
| Servicios (MySQL, PostgreSQL, Redis…) y sus versiones; crear bases para un proyecto | Cliente de bases de datos |
| Lenguajes y versiones; Utilidades | Terminal |
| Entornos `.env`, respaldo de la configuración, actualizaciones | Bóveda |
| Claves SSH de Stack (`sshKey*`, `config/ssh/keys/`) y su `known_hosts` | Correo y Dumps |
| Rama, cambios y carpetas de trabajo de cada proyecto (`gitStatus`, `web/projects/git.rs`) | AWS y Google Cloud |
| Dirección temporal y dirección fija de un proyecto; Registros | |
| Panel de la barra de menús y paleta de comandos | |

Las claves SSH y la verificación de huellas son de la base porque las usan dos herramientas (túneles del
cliente de bases y Terminal) y no deben perderse al desactivar una de ellas.

Regla: una herramienta solo **agrega** páginas, acciones y datos propios. La base no depende de ninguna
herramienta; una herramienta puede depender de la base y declarar qué piezas usa (`requires`).

## Catálogo

El motor expone `pluginCatalog`: una lista con, por herramienta,

| Campo | Ejemplo | Nota |
|---|---|---|
| `id` | `ssh-terminal` | `[a-z0-9-]`, estable |
| `version` | `1.0.0` | versión de la herramienta, independiente de la app |
| `size` | `0` | bytes a descargar; hoy siempre 0: todas van dentro de la app |
| `source` | `builtin` | hoy siempre `builtin` |
| `sha256` | — | obligatorio si algún día `size > 0` |
| `requires` | `["/usr/bin/ssh", "ssh-keys"]` | piezas de la base o del sistema |
| `installed`, `enabled`, `installedVersion`, `installedAt` | | estado del usuario |
| `hasData` | `true` | si guarda datos propios (se ofrecen al quitarla) |

El estado de las herramientas vive en `config/plugins.json` (0600). Correo y Dumps usan las secciones
`mail` y `dumps` de `stack.json`, que también consume el daemon; sus entradas antiguas en
`plugins.json` se descartan a favor de la configuración efectiva.

```json
{ "database-client": { "version": "1.0.0", "enabled": true, "installedAt": 1763000000 },
  "ssh-terminal":    { "version": "1.0.0", "enabled": true, "installedAt": 1763000000 } }
```

Métodos:

| Método | Qué hace |
|---|---|
| `pluginCatalog` | El catálogo con el estado del usuario |
| `pluginSetEnabled {id, enabled}` | Activa o desactiva; activar una que nunca se usó la registra (nada se descarga). Desactivar detiene lo que dejó corriendo (túneles del cliente de bases, reenvíos de la Terminal) |
| `pluginRemove {id, deleteData, confirmed}` | La quita del registro; con `deleteData` borra sus datos (la Bóveda responde `vault_data_kept`) |

Los métodos de una herramienta responden `plugin_disabled` si no está activa: la interfaz no es la única
barrera. Una sola compuerta, `app::plugins::tool_of`, dice a qué herramienta pertenece cada método, y
el despacho (`engine/src/main.rs`) la exige antes de todo: por prefijo (`db*`, `ssh*` salvo `sshKey*`,
`aws*`, `gcp*`, `mail*` y `setMail`, `dumps*` y `setDumps`) o por lista (`git::METHODS`). La prueba
`every_tool_method_answers_plugin_disabled_while_off` recorre todos los métodos del motor.

Si `plugins.json` no existe, el Cliente de bases de datos queda activo (lo usaban quienes ya lo tenían) y
la Bóveda siempre queda registrada y activa. Git empieza apagada en toda instalación, nueva o existente.

## Entrega

Todas las herramientas vienen compiladas en la app firmada: no se descarga código. Los campos de
descarga del catálogo quedan para recursos que se distribuyan por separado, con fuente, suma de
verificación y confirmación. Ver [decisiones.md](decisiones.md).
