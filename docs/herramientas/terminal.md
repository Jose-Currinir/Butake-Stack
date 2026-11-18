# Terminal

Terminal propia de Stack: consolas de este Mac y hosts SSH guardados, con pestañas, divisiones,
búsqueda, temas, fragmentos, SFTP y reenvíos de puertos.

- Motor: `engine/src/ssh/` (`hosts.rs`, `sftp.rs`, `snippets.rs`, `config.rs`, `common.rs`; `keys.rs`
  y `askpass.rs` son de la base).
- App: `native/Sources/ButakeStack/Tools/Terminal/` (hosts, SFTP, fragmentos, reenvíos y consolas
  locales); las claves, que son de la base, en `SSHKeys/` con su propia sesión (`SSHKeyring`).
- Id del catálogo: `ssh-terminal`. Requiere `/usr/bin/ssh` y las claves SSH de la base.

## Cómo se activa

Ajustes › Herramientas › Terminal. Sin `config/plugins.json` empieza apagada. Apagarla detiene los
reenvíos (`stop_all`) y cada `ssh*` (salvo `sshKey*`) responde `plugin_disabled`. «Eliminar datos»
borra los hosts y los fragmentos; nunca las claves SSH.

Otras herramientas la usan: «Abrir consola aquí» de un proyecto, «Abrir asistente aquí» de Git e
«Iniciar sesión…» de Google Cloud. Sin la Terminal encendida no se ofrecen o llevan a su fila de
Ajustes.

## Qué hace

- **Este Mac:** «Consola» (el shell de inicio del usuario, `$SHELL -l`) y una fila por asistente de
  terminal que detecta la página Utilidades (`devTools`); lo no instalado no aparece. Un asistente
  arranca a través del shell de inicio, que luego se convierte en él (`exec "$0"`). La carpeta inicial
  es la personal, o la del proyecto desde «Abrir consola aquí»; ahí el `PATH` lleva primero las
  versiones del proyecto (`siteShellEnvironment`: `PATH`, `JAVA_HOME`, `VIRTUAL_ENV`, el enlace de
  Google Cloud), nunca su `.env`. Cerrar la pestaña cuelga el PTY, envía SIGHUP a la sesión, SIGKILL a
  lo que siga vivo y recoge el proceso. Stack no guarda historial ni salida.
- **Hosts guardados:** nombre, descripción, grupo, etiquetas, servidor, puerto, usuario, autenticación
  (clave de Stack por id, clave dentro de `~/.ssh` o agente) y un salto opcional (otro host guardado;
  un solo salto).
- **Huellas:** `StrictHostKeyChecking=yes` contra `~/.ssh/known_hosts` y el de Stack. `sshHostCheck`
  compara lo que presenta el servidor (`ssh-keyscan`) con lo conocido; detrás de un salto, exige
  primero el salto conocido y lee la clave a través de él con un `known_hosts` desechable. Lo ya
  verificado en la sesión no se vuelve a escanear.
- **Salto:** `ProxyCommand` con `/usr/bin/ssh -W [%h]:%p` y las mismas opciones verificadas del salto.
- **Sesión interactiva:** terminal embebida (SwiftTerm, MIT, versión fija; licencia en
  `Contents/Resources/Acknowledgements`) que ejecuta en un PTY los argumentos de `sshSession`. «Abrir en
  Terminal» (`sshOpen`) es la opción secundaria, con un `.command` temporal.
- **Fragmentos:** globales o por host; solo texto, tabuladores y saltos de línea. «Insertar» usa pegado
  entre corchetes (no ejecuta); «Ejecutar» además envía Enter.
- **SFTP:** `/usr/bin/sftp -b` con las mismas opciones; borrar carpetas recorre el árbol sin seguir
  enlaces; las transferencias corren en un PTY para leer el progreso.
- **Importar `~/.ssh/config`:** parser propio (`Include`, `Host *`, el primer valor gana, `Match`
  ignorado), vista previa y selección; el archivo solo se lee.
- **Reenvíos de puertos** por host: local (`-L`), remoto (`-R`) y dinámico (`-D`), siempre en
  `127.0.0.1`, con `ssh -N` en `BatchMode`. Con «Reiniciar» la app los reabre si se caen (`sshHeal`,
  espera creciente hasta 5 minutos).

## Métodos del motor

| Método | Qué hace |
|---|---|
| `sshHosts` | Hosts, reenvíos activos y caídos |
| `sshSaveHost`, `sshUpdateHosts`, `sshDeleteHost` | Guarda uno, varios a la vez (atómico) o borra un host |
| `sshHostCheck`, `sshTrust` | Compara las claves del servidor y confía en las que el usuario vio |
| `sshSession` | Ejecutable y argumentos de la sesión (la app los corre en su PTY) |
| `sshCommand` | La línea de comandos equivalente, para copiar |
| `sshOpen` | Abre la sesión en un `.command` temporal |
| `sshForwardStart`, `sshForwardStop`, `sshHeal` | Reenvíos de puertos |
| `sshSnippets`, `sshSnippetSave`, `sshSnippetDelete` | Fragmentos |
| `sshConfigPreview`, `sshConfigImport` | Importar `~/.ssh/config` |
| `sshSftpList`, `sshSftpMkdir`, `sshSftpRename`, `sshSftpDelete`, `sshSftpTransfer`, `sshSftpDone` | SFTP |

Base (sin herramienta): `sshKeys`, `sshKeyImport`, `sshKeyGenerate`, `sshKeyUpdate`, `sshKeyDelete`,
`sshKeyPublic`, `sshKeyAgent`, `sshKeyAgentLoad`, `sshKeyAgentUnload`. Ver
[herramientas.md](../herramientas.md#qué-es-base-y-qué-es-herramienta).

## Datos que guarda

| Qué | Dónde |
|---|---|
| Hosts | `config/ssh/hosts.json` (0600) |
| Fragmentos | `config/ssh/snippets.json` |
| Huellas aceptadas en Stack | `config/ssh/known_hosts` (base) |
| Claves de Stack | `config/ssh/keys/<id>` (0600 en carpeta 0700; base) |
| Frases de paso | Llavero, `cl.butake.stack.ssh-key` (base) |
| Reenvíos en marcha | `run/forward-<host>--<reenvío>.json` y `.log` (0600) |

## Seguridad

- Sin shell: `/usr/bin/ssh` con argumentos separados. El `.command` solo contiene `exec` con argumentos
  entre comillas simples; host y usuario se validan (`[A-Za-z0-9._:-]`, sin `-` inicial) y van después
  de `--`.
- `ControlMaster=no`, `IdentitiesOnly=yes` cuando hay clave, entorno vacío salvo `HOME` y
  `SSH_AUTH_SOCK`.
- La frase de una clave llega a `ssh-add`/`ssh-keygen` por `askpass.rs`: el propio motor hace de
  `SSH_ASKPASS` y la entrega por un socket Unix privado (0700, token de un uso), nunca por argumentos,
  variables, archivos ni registros.
- Reenvíos solo en `127.0.0.1`; los remotos se abren en el loopback del servidor.
- Un PID guardado solo se detiene si sigue siendo un `ssh`.

## Enlaces

- `butakestack://tool/ssh-terminal`: abre la herramienta.
- `butakestack://ssh/<host>`: selecciona ese host; nunca conecta solo. Apagada, abre Inicio.

## Límites conocidos

- Un solo salto por host, sin cadenas.
- Pocas pruebas: `SSHTests.swift`, `LocalConsoleTests.swift`, `KeysAndCloudTests.swift` (claves y quién
  las usa) y las del motor (`ssh/hosts/tests.rs` y en línea).
