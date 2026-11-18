# Cliente de bases de datos

Cliente para MySQL, MariaDB, PostgreSQL, Redis, Valkey y SQLite: los servicios de Stack aparecen como
conexiones propias, y el usuario guarda las suyas (locales o por un túnel SSH).

- Motor: `engine/src/db/` (`client.rs`, `session.rs`, `sql.rs`, `ddl.rs`, `export.rs`, `history.rs`,
  `ops/`).
- App: `native/Sources/ButakeStack/Database/`.
- Id del catálogo: `database-client`. Requiere los clientes de cada servicio y las claves SSH de la base.

Los servicios (instalar, iniciar, versiones) son de la base: Componentes › Servicios. Crear una base
para un proyecto desde Entornos (`createDatabase`, `rotateDatabasePassword`, `postgres*`) también es de
la base (`engine/src/web/services/databases.rs`, `web/services/postgres_auth.rs`).

## Cómo se activa

Ajustes › Herramientas › Cliente de bases de datos. Sin `config/plugins.json` queda encendido (lo
usaban quienes ya lo tenían). Apagarlo cierra los túneles de todas las conexiones; cada `db*` responde
`plugin_disabled`. «Eliminar datos» borra las conexiones guardadas.

## Qué hace

- Conexiones guardadas con nombre, tipo, servidor, TLS, túnel SSH opcional (`/usr/bin/ssh -L` con
  huellas verificadas), modo solo lectura y marca de producción (cada cambio pide escribir otra vez el
  nombre de la conexión).
- Explorar bases, tablas, filas y estructura; editar filas; editor SQL con historial, pestañas,
  `EXPLAIN` y transacciones manuales; diagrama del esquema; cambios de estructura (crear o modificar
  tablas, columnas, índices y claves foráneas por `dbDdl`).
- Usuarios y procesos del servidor; claves de Redis y Valkey.
- Volcar y restaurar, exportar resultados e importar CSV.
- Consola del cliente del servicio (`dbTerminal`); las SQL abren de solo lectura.
- PostgreSQL de Stack que confía sin contraseña: «Exigir contraseña…» y «Volver a entrar sin
  contraseña…» (ver [architecture.md](../architecture.md#seguridad)).

## Métodos del motor

| Método | Qué hace |
|---|---|
| `dbConnections`, `dbSaveConnection`, `dbDeleteConnection` | Lista, guarda o borra conexiones |
| `dbTest`, `dbSshFingerprints`, `dbSshTrust` | Prueba una conexión y verifica la huella del túnel |
| `dbDisconnect`, `dbDisconnectAll` | Cierra sesiones y túneles (todos al salir de la app) |
| `dbDatabases`, `dbObjects`, `dbRows`, `dbStructure`, `dbSchema` | Explorar |
| `dbRun`, `dbExplain` | Ejecutar SQL y explicar un plan |
| `dbEdit` | Editar filas (exige clave primaria) |
| `dbDdl` | Cambios de estructura (`createTable`, `addColumn`, `alterColumn`, `dropColumn`, `createIndex`, `dropIndex`, `addForeignKey`, `dropForeignKey`, `renameTable`, `dropTable`) |
| `dbTxBegin`, `dbTxCommit`, `dbTxRollback`, `dbTxStatus` | Transacción manual del editor |
| `dbCreateDatabase`, `dbDropDatabase`, `dbUsers`, `dbCreateUser`, `dbDropUser`, `dbSetRootPassword` | Administración |
| `dbProcesses`, `dbKill` | Procesos del servidor |
| `dbRedisKeys`, `dbRedisValue`, `dbRedisDelete` | Redis y Valkey |
| `dbDump`, `dbRestore`, `dbExport`, `dbImportCsv` | Volcados, exportar e importar |
| `dbTerminal` | Consola del cliente del servicio |
| `dbHistory`, `dbHistoryAdd`, `dbHistoryClear`, `dbQueryTabs`, `dbSaveQueryTabs` | Historial y pestañas del editor |

Los métodos que cambian algo se rechazan en una conexión de solo lectura antes de hacer nada
(`read_only_connection`). Subcomando: `butake-stack dbsession` (sesión persistente, ver abajo).

## Datos que guarda

| Qué | Dónde |
|---|---|
| Conexiones (sin contraseñas) | `config/connections.json` |
| Historial de consultas | `db-history/<conexión>.json` |
| Pestañas del editor | `db-tabs/<conexión>.json` |
| Sesiones persistentes y túneles | `run/` (sockets privados y estado) |
| Contraseñas de conexiones y la de root del MySQL de Stack | Llavero, `cl.butake.stack.db` (`.qa` con un almacén de pruebas) |

## Seguridad

- Las contraseñas viven en el Llavero de la app y viajan en cada pedido; el motor nunca las guarda. La
  del superusuario del PostgreSQL de Stack la pone el motor (`stack_password`): la app nunca la tiene.
- Las sentencias corren con los clientes del propio servicio (`mysql`, `psql`, `redis-cli`, `sqlite3`)
  sin shell, con salida legible por máquina.
- Sesiones de lectura persistentes (`db/session.rs`): una por conexión, base y contraseña, tras un socket
  Unix privado en `run/`; se cierran tras 10 minutos sin uso (30 con una transacción abierta). Las
  escrituras nunca pasan por ellas.
- Túneles con `StrictHostKeyChecking` y las claves de la base. Errores del servidor llegan como
  `database_error` con un detalle de hasta 2.000 caracteres.

## Enlaces

- `butakestack://tool/database-client`: abre la herramienta.
- `butakestack://db/<conexión>`: selecciona esa conexión; nunca conecta sola. Apagada, abre Inicio.

## Límites conocidos

- MongoDB, Meilisearch, Typesense y RustFS no tienen cliente (`unsupported_engine`).
