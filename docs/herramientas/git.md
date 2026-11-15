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
- Fichas de proveedores (R19): solo en el Llavero, leídas la primera vez que hacen falta y enviadas solo
  en la cabecera `Authorization` de pedidos HTTPS al anfitrión de la API del proveedor (sesión efímera,
  sin redirección a otro anfitrión). Nunca llegan al motor, a Git, a disco ni a la interfaz. Todo lo
  que crea algo en el proveedor se confirma; un repositorio nuevo es privado por defecto.
- Autores de commits (R18): se leen en el momento, nunca se guardan.

## Enlaces

- `butakestack://tool/git`: abre la herramienta (apagada, Ajustes › Herramientas con su fila).
- `butakestack://git?path=<repositorio>` (por ejemplo `butakestack://git/open?path=/Users/ana/codigo/tienda`):
  abre ese repositorio si la herramienta está encendida; si no, se comporta como `tool/git`.

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
