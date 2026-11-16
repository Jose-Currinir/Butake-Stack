# Git

Cliente de Git dentro de Stack: repositorios, cambios, commits, historial, ramas, conflictos, pull
requests y problemas. Es el motor de la app Butake Git, traído casi literal, con una interfaz rehecha
con las reglas de Stack.

- Motor: `engine/src/git/` (pruebas en `engine/src/git/tests/`).
- App: `native/Sources/ButakeStack/Git/`.
- Id del catálogo: `git`. Requiere el `git` del Mac.

Lo que un proyecto sabe de su repositorio (rama, cambios, carpetas de trabajo, `gitStatus`,
`addWorktreeSite`, `branchChanges`) es de la base y vive en `engine/src/web/projects/git.rs`; no necesita la
herramienta. Ver [proyectos.md](../proyectos.md).

## Cómo se activa

Ajustes › Herramientas › Git. Empieza apagada en toda instalación, nueva o existente. Apagada no
aparece en la barra lateral, la paleta, los menús, el panel de la barra de menús ni Ajustes (la
pestaña Cuentas desaparece), deja de vigilar carpetas y cada `git*` responde `plugin_disabled`
(también el subcomando `git-console`).

## Qué hace

- **Ventana:** selector de repositorio (proyectos de Stack con repositorio, agregados y recientes;
  «Agregar repositorio…», «Clonar…», «Crear…»), pestañas Cambios, Historial, Ramas, Pull requests y
  Problemas (⌥⌘1…⌥⌘5), un botón principal que cambia con el estado y «Más…» (guardados, etiquetas,
  remotos, carpetas de trabajo y archivos).
- **Proyecto:** con la herramienta encendida, la página suma «Abrir en Git», la cuenta de problemas y,
  sin repositorio, «Crear repositorio aquí» (no dentro de otro repositorio).
- **Proyectos de varias partes:** el selector y el panel de la barra de menús agrupan sus
  repositorios (los de sus partes y los agregados con «Agregar repositorio al proyecto…», guardados en
  `groups.json`) y suman sus problemas. Ver, actualizar (`fetch`) y bajar son conjuntos; confirmar y
  subir siguen siendo de un repositorio a la vez.
- **Barra de menús:** lista los repositorios con cambios, por bajar o subir y problemas, con «Bajar»,
  «Subir» (nunca en la rama principal desde ahí) y «Abrir» (`Git/MenuBar/`). «Buscar cambios cada 5
  minutos» viene apagado (preferencia `git.autoFetch`).
- **Diccionario** (menús Git y Ayuda, ⌥⌘D): los 152 comandos de `engine/src/git/commands.json` con su
  explicación, si el Git del Mac los trae, su documentación y las palabras de Git
  (`Resources/GitDictionary.json`).
- **Asistente:** «Abrir asistente aquí» abre un asistente detectado o la consola en la Terminal de
  Stack, en el repositorio o en una carpeta de trabajo. Solo con la Terminal encendida.
- **Traer de Butake Git:** «Traer mis repositorios…» (`Git/Migration/`) lee una vez, a pedido, el
  archivo de preferencias de esa app (`~/Library/Preferences/cl.butake.git.native.plist`, solo
  lectura): sus recientes que sigan en el Mac, «Buscar cambios cada 5 minutos» y la carpeta para
  clonar. Las cuentas no se copian entre llaveros. Se ofrece una vez por Mac.
- **GitHub y Bitbucket Cloud** (`Git/Hosting/`): pull requests (lista, detalle, comprobaciones,
  revisiones, comentarios, crear, aprobar, comentar, combinar), lista de repositorios para clonar,
  crear y publicar un repositorio, y la protección de la rama principal leída del proveedor. Las
  comprobaciones fallidas van a Problemas (`GitHostingProblems`).

Acciones propias de Stack en `gitAction` (sin consola): terminar (`continue_operation`) o cancelar
(`abort_operation`) una combinación, reorganización, copia o reversión a medias; rama
(`create_branch_at`) o etiqueta (`create_tag`, `delete_tag`) en un commit; aplicar o borrar un
guardado (`stash_apply`, `stash_drop`); agregar o quitar un remoto (`add_remote`, `remove_remote`);
fijar la identidad (`set_identity`, `set_global_identity`); ignorar un archivo (`ignore_path`); crear o
quitar una carpeta de trabajo (`add_worktree`, `remove_worktree`; nunca la principal, nunca forzada).
`gitQuery` admite `grep` sin paginador (`-O`), sin patrones desde archivo (`-f`) y sin `--no-index`.

## Métodos del motor

Lista en `git::METHODS` (`engine/src/git/mod.rs`). `path` es el repositorio (o la carpeta padre en
`gitClone` y `gitInit`). La columna «Butake Git» da el nombre original del método.

| Método | Parámetros | Butake Git | Usado por la app |
|---|---|---|---|
| `gitCapabilities` | — | `capabilities` | Sí |
| `gitHelp` | `command` | `help` | Sí |
| `gitRepositories` | — | — | Sí |
| `gitRepositoryAdd` | `path` | — | Sí |
| `gitRepositoryForget` | `path` | — | Sí |
| `gitClone` | `path` (padre), `url`, `name` | `clone` | Sí |
| `gitSshAccess` | `url`; responde si la dirección usa SSH, su servidor y puerto, si el servidor está en `~/.ssh/known_hosts` y si hay una clave que ofrecer (en el agente o una por omisión de `~/.ssh`) | — | Sí |
| `gitSshFingerprints` | `url`; las huellas que el servidor presenta ahora y si son las que publica su proveedor | — | Sí |
| `gitSshTrust` | `url`, `fingerprints` (las que vio el usuario), `confirmed`; agrega el servidor a `~/.ssh/known_hosts` | — | Sí |
| `gitInit` | `path` (padre), `name`, `develop` | `init` | Sí |
| `gitPublish` | `url`, `branches`, `replaceOrigin`, `confirmed` | `publish` | Sí |
| `gitOpen` | `limit`, `stats`; lo anota en recientes (hasta 20) | `open` | Sí |
| `gitSnapshot` | `limit`, `stats` | `snapshot` | Sí |
| `gitChanges` | — | `status` | Sí |
| `gitStats` | — | `stats` | Sí |
| `gitRewriteCandidates` | — | `rewriteCandidates` | Sí |
| `gitRewriteApply` | `plan`, `confirmed` | `rewriteApply` | Sí |
| `gitRewriteUndo` | `backup`, `confirmed` | `rewriteUndo` | Sí |
| `gitBranchSync` | `left`, `right` | `branchSync` | Sí |
| `gitCopyCommits` | `target`, `hashes`, `confirmed` | `copyCommits` | Sí |
| `gitSetRemoteProtection` | `value` (`true`, `false`, `unknown`) | `setRemoteProtection` | Sí |
| `gitSetMainProtection` | `value` (`true`, `false`, `auto`), `confirmed` | `setMainProtection` | No |
| `gitStagePaths` | `paths`, `staged` | `stagePaths` | Sí |
| `gitBranchDetails` | `branch`, `base` | `branchDetails` | Sí |
| `gitReadFile` | `file` | `readFile` | Sí |
| `gitDiff` | `file`, `staged`, `whole` | `diff` | Sí |
| `gitAction` | `action`, `value`, `confirmed` | `action` | Sí |
| `gitPrepare` | `command`, `arguments` | `prepare` | No |
| `gitRun` | `command`, `arguments`, `confirmed` | `run` | No |
| `gitQuery` | `args` (solo lectura) | `query` | Sí |
| `gitRebaseCandidates` | `base` | `rebaseCandidates` | No |
| `gitValidateRebase` | `plan` | `validateRebase` | No |
| `gitStageHunk` | `file`, `staged`, `index`, `expected` | `stageHunk` | Sí |
| `gitConflict` | `file` | `conflict` | Sí |
| `gitResolveConflict` | `file`, `content`, `expected`, `confirmed` | `resolveConflict` | Sí |

Subcomandos del binario: `butake-stack git-console <repositorio> <comando> <argumentos> [plan]`
(consola en una pestaña de la Terminal, con la misma política que `gitPrepare`) y
`butake-stack git-write-plan` (editor de secuencia del rebase interactivo).

Errores: `{"code", "messageKey": "git.error.<code>", "detail"}`. `code` es fijo; `detail` es el
mensaje del motor o la salida de Git, sin credenciales (filtro de `daemon/redact.rs`) y con 4.000
caracteres como máximo. Solo los `git*` aceptan solicitudes de más de 1 MiB (hasta 16 MiB).

## Datos que guarda

| Qué | Dónde |
|---|---|
| Repositorios agregados y recientes (solo rutas y fechas) | `config/git/repositories.json` (0600) |
| Repositorios agregados a un proyecto de varias partes | `groups.json`, campo `repositories` |
| Cuentas de GitHub y Bitbucket | Llavero, servicio `cl.butake.stack.git.accounts`, un ítem por cuenta (`<proveedor>/<usuario>`) |
| Último repositorio abierto, `git.autoFetch` | Preferencias de la app |
| Respaldo antes de reorganizar | `refs/butake/backup/<rama>/<epoch>` en el propio repositorio |
| Protección de la rama principal | `butake.protectMain` y `butake.remoteProtectMain` en la configuración local del repositorio |

«Eliminar datos» borra `config/git/` y nunca toca los repositorios.

## Seguridad

- Git corre con argumentos separados, `GIT_TERMINAL_PROMPT=0`, `GIT_OPTIONAL_LOCKS=0` y el entorno del
  usuario (agente SSH, gestores de credenciales, hooks). Stack no guarda tokens ni contraseñas de Git.
- Tiempos: 12 s las lecturas rápidas, 120 s las comunes, 15 min commit, combinación y reorganización,
  30 min la red (`git/runner.rs`). El motor espera al proceso, no al cierre de sus tuberías.
- Rama principal (`main` o `master`) protegida por repositorio; confirmación en lo destructivo, al
  subir y en la consola; subida con destino explícito, nunca forzada ni masiva (`--force`, `+refspec`,
  `--mirror`, `--all`, `--tags`, `--delete`); corregir o deshacer el último commit solo si no está en
  ninguna rama remota; referencias por stdin bloqueadas.
- Límites de lectura: editor 2 MB, vista de archivo nuevo 1 MB, conteo de líneas 2 MB. El editor nunca
  abre `.git` ni enlaces simbólicos y solo guarda si el archivo, HEAD y la rama siguen iguales.
- Las URL salen sin usuario ni contraseña; la salida de `remote`/`config` y los errores pasan por el
  filtro de credenciales.
- Fichas de proveedores (R19): solo en el Llavero, leídas la primera vez que hacen falta y enviadas en
  la cabecera `Authorization` de pedidos HTTPS al anfitrión de la API del proveedor (sesión efímera,
  sin redirección a otro anfitrión) y, en memoria, a Git en una transferencia por HTTPS con ese mismo
  proveedor (ver «HTTPS con la ficha de la cuenta»). Nunca llegan a disco ni a la interfaz. Todo lo
  que crea algo en el proveedor se confirma; un repositorio nuevo es privado por defecto.
- Autores de commits (R18): se leen en el momento, nunca se guardan.

## Enlaces

- `butakestack://tool/git`: abre la herramienta (apagada, Ajustes › Herramientas con su fila).
- `butakestack://git?path=<repositorio>` (por ejemplo `butakestack://git/open?path=/Users/ana/codigo/tienda`):
  abre ese repositorio si la herramienta está encendida; si no, se comporta como `tool/git`.

## HTTPS con la ficha de la cuenta

Con GitHub o Bitbucket Cloud conectados, clonar, traer, bajar, subir y publicar por HTTPS usan la ficha de
esa cuenta (R19), sin configurar nada en Git. «Clonar…» propone HTTPS por defecto.

- La app agrega `credentials` (`origin`, `username`, `password`) al pedido (`gitClone`, `gitPublish`,
  `gitAction` de red) solo si el remoto es una dirección `https://` del proveedor y hay cuenta
  (`GitHosting.transferCredentials`). Usuario: `x-bitbucket-api-token-auth` en Bitbucket Cloud, el de la
  cuenta en GitHub.
- El motor (`engine/src/git/credentials.rs`) las acepta solo si la dirección a clonar o publicar, o un remoto
  del repositorio, es de ese origen; si no, las descarta. Para `clone`, `fetch`, `pull` y `push` apaga los
  gestores de credenciales de Git (`-c credential.helper=`) y apunta `GIT_ASKPASS` a sí mismo: cuando Git
  pregunta, el ayudante consulta por un socket Unix privado y recibe respuesta solo si la pregunta es por ese
  origen. La ficha no queda en la dirección del remoto, en `.git/config`, en argumentos ni en archivos.
- Con SSH, con otro servidor o sin cuenta, Git funciona como antes (claves y gestores del usuario).
- Subir exige una ficha con permiso de escritura de repositorios; las creadas con los permisos anteriores
  solo leen.

## Acceso por SSH al clonar

El `ssh` de Git no puede preguntar nada (sin terminal): en un Mac sin `~/.ssh/known_hosts` ni claves, un
clon por SSH fallaba sin salida dentro de la app. «Clonar…» pregunta antes con `gitSshAccess` y muestra lo
que falta, cada cosa con su acción:

- **Servidor sin confirmar** (`clone_host_unknown`): «Revisar huella…» lee las huellas con `ssh-keyscan`,
  las muestra y, al aceptar, `gitSshTrust` vuelve a leerlas y solo si siguen siendo las mismas las agrega a
  `~/.ssh/known_hosts` (0600; `~/.ssh` 0700 si no existía). Para `github.com` y `bitbucket.org` (puerto 22)
  se comparan además con las que publica cada proveedor (`OFFICIAL` en `engine/src/git/access.rs`): un
  servidor que responde por esos nombres con otra clave se rechaza aunque el usuario acepte. «Clonar» queda
  desactivado mientras el servidor no esté confirmado.
- **Sin clave que ofrecer**: con claves en Stack, «Usar una clave» carga la elegida en el agente (dura lo
  que la sesión del Mac); sin ninguna, lleva a Ajustes › Claves SSH.
- **Clave no registrada** (`clone_ssh_denied`): copiar la clave pública y abrir la página de claves SSH del
  proveedor. Stack no la registra por la API: la ficha no pide ese permiso.
- **HTTPS rechazado** (`clone_auth`): con la cuenta conectada, la ficha no da acceso a ese repositorio
  (lleva a Ajustes › Cuentas para conectar otra); sin cuenta o con otro servidor, lo explica. En ambos
  casos ofrece pasar a SSH.

Nada de esto lee una clave privada. Las pruebas usan una carpeta personal
temporal y las claves públicas de los proveedores como texto, sin red (`engine/src/git/tests/access.rs`).

## Límites conocidos

- Cinco métodos no tienen llamada desde la app (columna «Usado por la app»): se conservan para la
  línea de comandos y la consola. Los que no usaba nadie se quitaron en R-1 (ver
  [architecture.md](../architecture.md#métodos-del-motor-sin-llamada-desde-la-app)).
- No se trajeron a la interfaz: el rebase interactivo (el motor conserva `git-console` y
  `git-write-plan`), la consola propia de Git (la Terminal de Stack la reemplaza), el editor con
  guardado (el visor es de solo lectura) ni cambiar la protección de `main` (solo se lee).
- Sin marcas de revisado en lotes grandes; sin panel junto al notch (su estado pasa a la barra de menús).
- Pruebas y QA usan un servidor falso de proveedores (`QA/GitHostingFakeServer.swift`,
  `BUTAKE_QA_GIT_HOSTING=fake`): nada se probó contra GitHub ni Bitbucket reales.
- El «último repositorio abierto» deja de proponerse si se cambió la carpeta del proyecto.
