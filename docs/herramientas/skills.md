# Skills

Guarda tus skills (instrucciones en texto que las IA cargan según la tarea) en un solo lugar, las
ordena en grupos y las enlaza a las carpetas de Claude, Codex y Gemini sin copiarlas. Para ChatGPT, que
no tiene carpeta de skills, las exporta como texto listo para pegar.

- Motor: `engine/src/skills/` (`mod.rs` despacho y operaciones, `index.rs`, `skill_file.rs`,
  `agents.rs`, `links.rs`, `health.rs`, `export.rs`, `templates.rs`, `trash.rs`; pruebas en
  `engine/src/skills/tests/`).
- App: `native/Sources/ButakeStack/Skills/` (archivos `Skill*`).
- Id del catálogo: `skills`. No requiere programas externos (`requires` vacío).

## Cómo se activa

Ajustes › Herramientas › Skills. Empieza apagada en toda instalación (sin entrada en `plugins.json`).
Apagada no aparece en la barra lateral, la paleta ni los menús, y cada `skills*` responde
`plugin_disabled`. Desactivarla no borra nada ni quita enlaces; «Eliminar datos…» (Ajustes ›
Herramientas) quita los enlaces que Stack creó en las carpetas de las IA y borra `skills/` y
`skills-trash/`, con confirmación.

## Qué hace

- **Una sola copia:** cada skill es una carpeta con su `SKILL.md` en la carpeta de datos de Stack. Las
  IA reciben un enlace simbólico a esa carpeta (`<carpeta de la IA>/<id>`), nunca una copia.
- **Grupos:** Personal, Trabajo y Butake de partida; se crean, renombran, reordenan y eliminan. Las
  carpetas son planas: el grupo y las etiquetas viven solo en `index.json`, así que mover una skill de
  grupo o renombrar un grupo nunca toca un enlace.
- **IA incluidas:** Claude (`~/.claude/skills`), Codex (`~/.agents/skills`, la carpeta que Codex
  lee; la comparten otras IA) y Gemini (`~/.gemini/skills`) por enlace; ChatGPT y Kiro solo por exportación. Se pueden agregar IA propias con
  nombre y carpeta (`skillsAgentSave`).
- **Plantillas:** En blanco, Commits y Publicar app (`templates.rs`). El `SKILL.md` queda portable: su
  encabezado trae solo `name` y `description`; lo propio de Stack no va en el archivo.
- **Edición:** el editor guarda el `SKILL.md` completo (máximo 256 KiB) y vuelve a leer `name` y
  `description` del encabezado. Duplicar copia la carpeta sin seguir enlaces y la deja sin IA.
- **Cambios fuera de Stack:** si `SKILL.md` cambia en el disco mientras el editor está abierto, se recarga
  cuando no hay texto sin guardar; si lo hay, el editor avisa y deja elegir entre recargar o conservar lo
  escrito (guardar entonces reemplaza la versión del disco). Cambiar de skill con texto sin guardar pide
  confirmación; también cambiar el grupo, la etiqueta o la IA de «Filtros» cuando el filtro nuevo dejaría de mostrar
  la skill abierta (si la sigue mostrando, o si «Limpiar filtros» solo amplía la lista, se aplica sin preguntar).
  Un filtro que oculta la skill abierta sin texto sin guardar la cierra, como ya hacía el grupo.
- **Papelera:** eliminar una skill quita sus enlaces y mueve la carpeta a `skills-trash/`; «Deshacer»
  la restaura con sus enlaces donde el nombre siga libre. Lo que lleva más de 30 días se purga al
  listar. Pasado el aviso de «Deshacer», «Skills eliminadas…» (menú «⋯», sección «Papeleras», junto a
  «Papelera de importación…») lista lo que sigue en la papelera, con cuándo se eliminó y cuándo se borra sola, y
  «Restaurar…» abre la misma confirmación de enlaces que «Deshacer». No borra nada de forma definitiva.
- **Salud:** revisa sin cambiar nada y propone una acción por problema (ver abajo). La app la pide al abrir la herramienta, al abrir «Salud» y tras cambios de enlaces (relee los archivos de cada skill, por eso no se pide en cada cambio).

### Pantallas

Tres columnas, como las demás herramientas:

- **Columna de contenido:** selector Todas, un elemento por grupo y Salud; búsqueda, filtros por
  etiqueta y por IA, y «Grupos…» al pie.
- **Lista:** las skills del ámbito elegido.
- **Detalle:** nombre, descripción, grupo, etiquetas, última modificación y archivos de apoyo; una
  sección «IA» con un interruptor por IA (ChatGPT y Kiro ofrecen «Copiar texto»; las IA propias, Editar y
  Quitar) y el editor de `SKILL.md` (⌘S guarda).
- **Barra de herramientas:** «Nueva skill…» (con plantilla), Duplicar, Exportar… (copiar o guardar un
  `.md`) y «⋯» (Mover a grupo…, Renombrar…, Desactivar o Activar, Eliminar…).
- **Hoja de confirmación de enlaces:** antes de aplicar cualquier cambio a una carpeta de IA (enlazar,
  activar o desactivar, renombrar, eliminar, restaurar o quitar una IA propia) muestra las rutas
  exactas que se crean, las que se quitan y los conflictos.
- **Salud:** cada problema con su botón: escribir la descripción, reparar el enlace, renombrar,
  enlazar, mostrar en Finder o cambiar la carpeta.

### Salud

| Tipo | Significa |
|---|---|
| `no_description` | El encabezado no trae `description` |
| `broken_link` | Falta el enlace de una IA asignada, o hay un enlace a Stack cuya skill ya no existe |
| `conflict` | Algo que no es nuestro ocupa el nombre en la carpeta de la IA; no se toca |
| `duplicate_name` | Dos skills tienen el mismo `name` |
| `unused` | La skill no está enlazada a ninguna IA |
| `missing_folder` | Falta la carpeta de una skill o de una IA propia |
| `agent_path` | El texto de la skill (`SKILL.md` y sus archivos de texto de apoyo) nombra `<carpeta de una IA>/<id de la skill>` (por ejemplo `~/.claude/skills/<id>/`, también con el HOME absoluto) de una IA con carpeta a la que la skill no está enlazada (`skill`, `agent`, `path` = carpeta de esa IA); «Enlazar a esa IA…» abre la hoja de enlaces con el plan |

Sobre `agent_path`: solo cuenta la ruta con el id de la propia skill (la de otra skill no). Salud solo lee
para encontrar esas rutas: nunca reescribe el texto ni lo devuelve (sin fragmento ni línea). Lee archivos
regulares de texto (sin enlaces, sin binarios, de hasta 256 KiB cada uno, hasta 100 de apoyo y 2 MiB en total).
Recomendación: en el texto y los scripts de una skill, refiere los archivos de apoyo con rutas relativas a
la carpeta de la skill; una ruta a la carpeta de una IA solo funciona mientras esa IA esté enlazada. Las
plantillas ya lo hacen así.

## Métodos del motor

| Método | Qué hace |
|---|---|
| `skillsList` | Grupos, skills, IA (con `mode` `link` o `export`, `builtin`, `exists`) y etiquetas; purga la papelera de más de 30 días |
| `skillsRead {id}` | El texto completo de `SKILL.md` |
| `skillsCreate {id, group, template, name, description}` | Skill nueva desde `blank`, `commits` o `publish-app` |
| `skillsSave {id, text}` | Reemplaza `SKILL.md` (256 KiB como máximo) |
| `skillsUpdate {id, group?, tags?}` | Grupo y etiquetas (minúsculas, sin repetir, hasta 20) |
| `skillsDuplicate {id, newId}` | Copia sin IA. Los enlaces y archivos especiales de dentro no se copian ni se siguen: si los hubo, la respuesta trae `skipped` con sus rutas relativas y la app lo avisa |
| `skillsRename {id, newId, plan?, confirmed}` | Mueve la carpeta, cambia `name` del encabezado si era el id y recrea los enlaces. Aplicado responde `{skill, conflicts:[{path, reason}]}`: los nombres ya ocupados en la carpeta de una IA se omiten sin tocarlos y se devuelven (`exists`); la app los muestra con un acceso a Salud |
| `skillsDelete {id, plan?, confirmed}` | Quita sus enlaces, la manda a la papelera y devuelve `{trashId}` |
| `skillsRestore {trashId, plan?, confirmed}` | La trae de vuelta; sus enlaces, donde el nombre siga libre |
| `skillsTrashList {}` | Solo lectura: las skills eliminadas que siguen en la papelera, la más reciente primero: `[{trashId, id, name, description, deleted, expires, group}]` (`deleted` en segundos; `expires` = `deleted` + 30 días). Purga antes la papelera de más de 30 días, no lista las entradas de importación (`skillsImportTrashList`) y devuelve solo el título, nunca el texto ni los archivos. Restaurar usa `skillsRestore` con su `trashId` |
| `skillsGroupSave {groups}` | Crea, renombra y ordena grupos en una llamada |
| `skillsGroupDelete {id, moveTo}` | Elimina un grupo; `moveTo` es obligatorio si tiene skills |
| `skillsAgentSave {id, name, folder}` | Crea o edita una IA propia (las incluidas no se editan) |
| `skillsAgentRemove {id, plan?, confirmed}` | Quita una IA propia y sus enlaces |
| `skillsLinkPlan {changes}` o `{skill, enabled}` | Lo que se crearía, se quitaría y chocaría; no escribe nada |
| `skillsLinkApply {…, confirmed}` | Aplica el plan y actualiza `agents` y `enabled` en el índice |

Los cuatro métodos con `plan?` (renombrar, eliminar, restaurar y quitar una IA propia) responden
`plan: true` con `{create, remove, conflicts}`, la misma forma que `skillsLinkPlan`, sin escribir nada
(ni tomar el candado de escritura); la misma petición con `confirmed: true` en lugar de `plan` hace
exactamente eso. Sin `confirmed` responden `confirmation_required`. El plan de renombrar quita los
enlaces del id anterior y crea los del nuevo (un nombre ocupado en la carpeta de una IA es conflicto);
eliminar y quitar una IA solo quitan; restaurar solo crea, y los nombres ocupados son conflicto.
| `skillsHealth` | La lista de problemas de arriba |
| `skillsExport {id}` o `{ids, format}` | Texto Markdown (nombre, descripción, instrucciones y nombres de los archivos de apoyo) para pegar en ChatGPT o Kiro; hasta 50 skills |

Códigos propios: `skills_invalid_id`, `skills_exists`, `skills_not_found`, `skills_invalid_group`,
`skills_group_not_empty`, `skills_invalid_folder`, `skills_too_large`, `skills_link_conflict` y
`skills_agent_builtin`, `skills_import_choice_required`, `skills_import_choice_invalid`, `skills_import_verify` y `skills_import_failed`; además `confirmation_required`, `invalid_name` y `unsafe_store_path`.

## Datos que guarda

Todo en la carpeta de datos de Stack:

| Qué | Dónde |
|---|---|
| El índice (grupos, etiquetas, IA y, por skill, grupo, etiquetas, `enabled` e IA enlazadas) | `skills/index.json` (0600, escritura atómica) |
| La copia real de cada skill y sus archivos de apoyo | `skills/<id>/SKILL.md`, `skills/<id>/…` |
| Skills eliminadas, 30 días | `skills-trash/<id>-<epoch>/` con `entry.json` (su entrada del índice) y `files/` |
| Estado de la herramienta | `config/plugins.json` |

Fuera de la carpeta de datos, Stack solo crea enlaces simbólicos en las carpetas de las IA. Una
carpeta bajo `skills/` con `SKILL.md` y sin entrada en el índice se adopta en el primer grupo. Nada va
al Llavero. Si el usuario mueve la carpeta de datos (`migrate-data`), el plan y la migración incluyen,
con su reversión, esos enlaces (`place: skills`): los que apuntan a `skills/` de la carpeta anterior, en las
carpetas de las IA integradas y propias; los demás enlaces no se tocan.

## Importar skills existentes

Para skills que ya están en las carpetas de las IA (Claude, Codex, Gemini y las IA propias; nunca Kiro ni
ChatGPT, que solo exportan). En la app: «Más» › «Importar skills existentes…», o el botón de la pantalla sin
skills. Primero se elige qué importar, luego se ve el plan con todas las rutas y solo entonces se aplica.

| Método | Qué hace |
|---|---|
| `skillsImportScan {}` | Solo lee. Responde `[{id, name, description, sources:[{agent, path, kind, skipped?}], identical, valid, reason?, hidden}]`. Candidato: una entrada con `SKILL.md` que no es un enlace a la carpeta `skills/` de Stack. `kind` es `folder` o `link`; `skipped` lista las rutas de enlaces y archivos especiales de dentro, que la copia deja fuera. Las entradas que resuelven a la misma carpeta real, o cuyos árboles tienen los mismos bytes (hash de cada archivo regular; los enlaces de dentro no se siguen), son un candidato con varias fuentes. El mismo nombre con contenido distinto es `identical: false`. `valid: false` con `reason` `skills_invalid_id`, `skills_exists` o `skills_too_large`. Un nombre que empieza con punto (p. ej. `.sistema`) sale con `hidden: true`; como no cumple la regla de ids, tampoco es importable. Con topes de entradas, archivos y bytes |
| `skillsImportPlan {ids, group, choices:[{id, from}]}` | No cambia nada. `{copy:[{from, id}], replace, trash, unlink, conflicts:[{path, reason}]}`: `replace` es cada ruta que pasa a ser un enlace a Stack; `trash` las carpetas reales que van a la papelera de importación; `unlink` los enlaces ajenos, de los que solo se quita el enlace (su destino no se toca); `conflicts` las fuentes no elegidas (`not_chosen`), los ids inválidos y las rutas que no se pueden mover (`cannot_move`, p. ej. otro volumen). Solo se planifican los `ids` pedidos: una entrada oculta no entra si no se nombra. Plan y aplicación solo leen y calculan el hash de las carpetas de esos `ids`. Un candidato con copias distintas necesita `from` (una de sus rutas): sin él, `skills_import_choice_required`; con una ruta que no es suya, `skills_import_choice_invalid` |
| `skillsImportApply {…, confirmed}` | Sin `confirmed`, `confirmation_required`. Hace exactamente el plan y responde `{imported:[skill], conflicts}` |
| `skillsImportTrashList {}` | Las entradas de la papelera de importación: `[{trashId, id, created, path, sources}]` |
| `skillsImportUndo {trashId, plan?, confirmed}` | Deshace una importación (ver abajo). El plan responde `{restore:[{from, to}], relink:[{path, target}], remove, trash, conflicts}` |
| `skillsImportTrashEmpty {trashIds, plan?, confirmed}` | «Vaciar papelera de importación»: el plan responde `{delete:[rutas]}`; con `confirmed` borra solo esas carpetas y responde `{removed}` |

Al aplicar, cada skill se hace por separado:

1. Se copia la fuente elegida a una carpeta temporal dentro de la carpeta de datos, sin seguir enlaces, y se
   verifica el hash de cada archivo.
2. Se renombra a `skills/<id>` y entra en el índice (grupo elegido, activada, con las IA donde estaba).
3. Cada fuente se reemplaza por un enlace a la copia de Stack. Una carpeta real se **mueve** (rename) a
   `skills-trash/import-<id>-<epoch>/sources/<n>`, con un `entry.json` (ruta original, IA, hash de la
   copia); un enlace ajeno solo se quita (y se guarda adónde apuntaba).
4. Si algo falla, esa skill se revierte entera (copia, enlaces nuevos, carpetas devueltas, entrada del
   índice); las demás siguen.
5. No se borra nada: si mover una carpeta a la papelera falla (p. ej. otro volumen), esa fuente es un
   conflicto y queda intacta. No hay copiar y borrar.

La papelera de importación no se purga por antigüedad (a diferencia de la de skills eliminadas): queda
hasta que el usuario la vacía, y «Eliminar datos…» de la herramienta tampoco la toca. «Deshacer» una
importación mueve las carpetas originales a su lugar, vuelve a crear los enlaces ajenos, quita los enlaces
a Stack y manda la skill de Stack a la papelera de skills (30 días), solo si esa copia no cambió desde la
importación; si cambió, o una ruta original está ocupada, responde `{restored: [], conflicts}` y no hace
nada. Si la copia de Stack ya no existe (eliminada, renombrada o con «Eliminar datos…»), devuelve igual
las carpetas y los enlaces ajenos y no manda nada a la papelera. Vaciar es el único borrado definitivo y exige `confirmed` con la lista exacta de carpetas.

La hoja de la app muestra por skill desde dónde se copia, cada ruta que cambia («va a la papelera» o «solo se
quita el enlace»), las fuentes que quedan como están, y una advertencia general: otros programas con
enlaces a esas carpetas ahora llegarán a la carpeta de Stack. Códigos propios: `skills_import_choice_required`,
`skills_import_choice_invalid`, `skills_import_verify` y `skills_import_failed`.

## Seguridad (R23)

- Una skill es texto del usuario. Vive solo en la carpeta de datos de Stack; el motor no lo registra ni
  lo devuelve fuera de `skillsRead` y `skillsExport`. Ni errores ni la salud llevan texto: solo ids,
  rutas y códigos. Salud lee los archivos de la skill solo para encontrar rutas a carpetas de IA
  (`agent_path`) y no devuelve su contenido.
- `SKILL.md` se abre sin seguir enlaces (`O_NOFOLLOW`), debe ser un archivo regular de hasta 256 KiB, y
  guardar sobre un enlace falla con `unsafe_store_path`. Duplicar y listar archivos de apoyo tampoco
  siguen enlaces. Los ids son `[a-z0-9-]`, 1 a 64 caracteres, sin guion al principio ni al final.
- Los enlaces solo van a carpetas de IA bajo el HOME, resueltas con `canonicalize`: sin `..`, nunca el
  propio HOME, nunca la carpeta de datos de Stack ni una que la contenga. Una IA propia no puede repetir
  la carpeta de otra, ni cambiarla mientras tenga skills enlazadas.
- Solo se quita un enlace que apunta a la carpeta de esa skill dentro de `skills/`. Un archivo o una
  carpeta real con el mismo nombre en la carpeta de una IA no se toca: se informa como `conflict`
  (`exists`).
- Cada cambio de enlaces se planifica (`skillsLinkPlan`), se muestra con las rutas exactas y se aplica
  solo con `confirmed`; renombrar, eliminar, restaurar y quitar una IA también se planifican (`plan: true`), se
  muestran con las rutas exactas en la misma hoja y exigen `confirmed`.
- Única excepción a «solo se quitan enlaces que resuelven a `skills/`»: «Importar skills existentes…»
  reemplaza una carpeta real o un enlace ajeno por un enlace a Stack. Nunca borra (la carpeta real se mueve a
  la papelera de importación), muestra cada ruta antes de `confirmed`, la papelera se conserva hasta que el
  usuario la vacía y el borrado definitivo solo ocurre en «Vaciar papelera de importación» con `confirmed`.
- `~/.agents/skills` es una carpeta compartida entre IA: lo que otras herramientas pusieron ahí
  (carpetas reales, enlaces ajenos) es `conflict` (`exists`) y no se toca. Stack no lista, mueve ni toca nada de
  `~/.codex/skills` (incluidas las skills propias de Codex); no hay migración desde esa carpeta.
- Eliminar va a una papelera restaurable que se purga a los 30 días; «Eliminar datos…» borra además la
  papelera de skills, pero nunca la papelera de importación (ver «Importar skills existentes»).
- Pruebas y QA solo con un HOME y una carpeta de datos temporales; el motor recibe el HOME por
  parámetro (`dispatch_in`) y las pruebas no tocan las carpetas reales de ninguna IA.

## Enlaces

- `butakestack://tool/skills`: abre la herramienta.

## Kiro

Kiro (Kiro Crew) se incluye solo por exportación, nunca por enlace ni copia. Se verificó, leyendo el código
instalado de Kiro Crew (`skills_discovery.py`), que su escáner descarta un enlace simbólico en
`~/.kiro/crew/skills` cuyo destino queda fuera de sus raíces de confianza (su paquete y su carpeta de
apps), salvo que la carpeta esté en su propio ajuste `skills.extra_paths` (Ajustes › Skills). Un enlace a la
carpeta de datos de Stack se ignoraría sin aviso. Stack no lee ni escribe `~/.kiro` y no cambia los
ajustes de Kiro; si el usuario quiere cargar una carpeta de Stack, es una decisión suya en Kiro.

## Límites conocidos

- Solo un enlace por IA y skill, con el id como nombre: no hay nombres distintos por IA.
- ChatGPT y Kiro no tienen carpeta en Stack: solo se exporta texto, y los archivos de apoyo van por nombre, sin su
  contenido.
- Solo lee las carpetas de las IA para «Importar skills existentes…» (ver abajo); fuera de eso no las
  recorre. Una skill también se puede colocar a mano en `skills/<id>/` (se adopta).
- Restaurar («Deshacer») muestra antes los enlaces que recrea y exige `confirmed`; solo donde el
  nombre sigue libre, los ocupados se omiten y se informan como conflicto.
- Pruebas: motor en `engine/src/skills/tests/`; app en `SkillsTests.swift`.
