# Extensiones de los servicios

Stack administra las extensiones de sus servicios desde la app: se eligen de un catálogo, se
descargan a pedido de su origen oficial con verificación y se quitan sin dejar restos. Hoy las
ofrece PostgreSQL; el modelo es uno solo para cualquier componente que admita extensiones.

## Dos niveles

1. **Instalada en el servicio.** Sus archivos están en una versión instalada del servicio
   (`runtimes/postgres/<versión>/`). Lo que cada extensión dejó queda anotado en
   `butake-extensions.json`, junto al manifiesto de esa versión.
2. **Activa en una base.** `CREATE EXTENSION` en esa base. Cada base decide.

Hay tres clases:

| Clase | Qué es | Se instala o quita aparte |
|---|---|---|
| `bundled` | Viene con el servicio (las `contrib` de PostgreSQL: citext, pgcrypto, pg_trgm…) | No |
| `catalog` | Del catálogo de Stack, compilada a pedido (PostGIS, pgvector) | Sí |
| `builtin` | Integrada en el binario (los módulos de cada versión de PHP, y Xdebug) | No |

## Catálogo

| Extensión | Versión | Origen | Necesita |
|---|---|---|---|
| PostGIS | 3.7.0 | download.osgeo.org | GMP 6.3.0, GEOS 3.15.0, PROJ 9.9.0, JSON-C 0.19 y CMake 4.5.0 para compilar |
| pgvector | 0.8.7 | github.com/pgvector | — |

Cada archivo tiene su SHA-256 en `engine/src/runtimes/extensions/catalog.rs`: la que el proyecto
publica junto a su versión (GEOS, PROJ, JSON-C y CMake, en sus páginas de versiones) o, cuando el
proyecto solo publica MD5 o nada, la del archivo oficial fijada tras compararla con lo que sí
publica (PostGIS con su MD5; GMP, servido idéntico por sus dos orígenes oficiales; pgvector).
Una descarga que no coincide se descarta y no se instala nada.

PostGIS se compila con geometría, geografía, topología, el geocodificador y GeoJSON. Quedan fuera
los rásteres (exigirían GDAL) y las teselas vectoriales `ST_AsMVT` (exigirían protobuf-c).

## Cómo se instala

1. Se descargan el código y sus dependencias, y se comprueba cada suma.
2. Se extraen en una carpeta de trabajo sin espacios (la carpeta de datos de Stack está en
   `Application Support`, y los sistemas de compilación cortan las rutas en los espacios),
   junto a una copia del servicio.
3. Se compilan las bibliotecas que hagan falta y la extensión contra esa copia, con las
   herramientas del sistema y un ambiente vacío. CMake, cuando hace falta, se guarda en
   `build-tools/` de Stack para la siguiente vez. Nada se instala en el sistema.
4. Lo que cambió en la copia es lo que trae la extensión. Si reemplazaría un archivo del
   servicio, se rechaza (`extension_conflict`).
5. Las bibliotecas se reenlazan respecto del servicio (`@loader_path`) y se firman ad hoc; la
   ruta de trabajo no puede quedar en ninguna.
6. Solo entonces se copian al servicio, cada archivo escrito al lado y renombrado sobre su
   lugar. Los datos de PROJ quedan en `share/proj`, donde PROJ los busca junto a su biblioteca.

El progreso se sigue por pasos como el resto de instalaciones (`install-extension.log`), con
«Cancelar» real hasta que empieza a copiar.

**Actualizar** instala la versión nueva del catálogo sobre la anterior, borra lo que la nueva ya
no trae y, si el servidor está en marcha, pasa a esa versión cada base que la usa
(`ALTER EXTENSION … UPDATE`).

**Quitar** se rechaza mientras alguna base la tenga activa y dice cuáles; necesita el servidor en
marcha para saberlo.

**Otra versión del servicio.** Reconstruir la misma versión («Reinstalar con extensiones»)
conserva lo instalado. Una versión distinta empieza sin extensiones del catálogo: la página del
servicio dice cuáles estaban en otra versión y «Instalar en esta versión…» las instala en la nueva,
una tras otra, tras confirmar lo que descarga y con el progreso de cada una (se puede cancelar). Las
que no existen para la nueva versión se avisan aparte.

## En las bases

En el cliente de bases de datos, cada base de PostgreSQL de Stack tiene la pestaña
**Extensiones**: las activas, con «Desactivar…», y las disponibles, con «Activar…». Antes de
desactivar, Stack lista lo que depende de la extensión (una columna `geometry`, otra extensión);
si hay algo, la confirmación dice que se borra con ella. Al crear una base desde Entornos se
pueden marcar las extensiones que se activan al crearla.

## Proyectos

Un proyecto declara lo que necesita cada base:

```json
"databases": ["app", {"name": "geo", "extensions": ["postgis", "vector"]}]
```

Una base sin extensiones sigue escribiéndose como un nombre. Al encender el proyecto, y en su
Resumen, Stack comprueba los dos niveles y dice lo que falta: `notInstalled` (el catálogo la
tiene), `inactive`, `unsupported`, `unknown`, `databaseMissing`, `serverStopped` o
`serviceMissing`. «Resolver» instala lo del catálogo y activa lo declarado.

## Respaldos

«Mi entorno» exporta, por cada versión de PostgreSQL, qué extensiones del catálogo tiene
instaladas y, por cada base del servidor en marcha, cuáles están activas. Al restaurar, el plan
lista las que faltan en este Mac como una parte propia («Extensiones de los servicios»); si queda
marcada, «Aplicar» las instala después de los lenguajes y servicios, en la versión de PostgreSQL de
cada una, con el progreso de cada instalación. Los volcados de una
base ya incluyen sus `CREATE EXTENSION`.

## PHP

Las extensiones de PHP se listan con el mismo modelo (`extensionCatalog` con
`"component": "php"`), como `builtin`: vienen compiladas en el binario estático de cada versión,
así que no se instalan ni quitan por separado; una versión se instala o se reconstruye entera.
Xdebug viaja junto al binario y se enciende por versión en la página de PHP. Por eso PHP converge
en el modelo y el listado, pero no en el instalador.

## Otros servicios

El modelo admite después módulos de Redis y Valkey, o complementos de MySQL y MariaDB: una entrada
del catálogo con su componente, su receta de compilación y su forma de activarse. Hoy no hay
ninguno en el catálogo.

## Métodos del motor

| Método | Qué hace |
|---|---|
| `extensionCatalog` `{component, version?, series?}` | Lista las extensiones de una versión del servicio (o de una versión de PHP) |
| `installExtension` `{component, id, version?, confirmed}` | Instala o actualiza, seguida en `install-extension` |
| `removeExtension` `{component, id, version?, confirmed}` | Quita; rechazada con `extension_in_use` y las bases |
| `databaseExtensions` `{database}` | Activas y disponibles en una base |
| `activateExtension` `{database, name \| names, confirmed}` | `CREATE EXTENSION … CASCADE` |
| `extensionDependents` `{database, name}` | Lo que se perdería al desactivarla |
| `deactivateExtension` `{database, name, cascade, confirmed}` | `DROP EXTENSION`; con dependencias, solo con `cascade` |
| `projectExtensions` `{id}` | Lo que les falta a las bases de un proyecto |
| `resolveProjectExtensions` `{id, confirmed}` | Instala y activa lo que falta, seguida en `install-extension` |
| `extensionState` | Instaladas y activas, para respaldos |

## Pruebas

Las pruebas normales no usan la red: un PostgreSQL falso y un origen local recorren la misma
instalación, el registro, la conservación al reconstruir y el retiro. La corrida completa compila
de verdad en un almacén temporal cuya ruta tiene espacios:

```sh
cd engine
BUTAKE_P43_LIVE=1 cargo test --test extensions_live -- --ignored --nocapture
```
