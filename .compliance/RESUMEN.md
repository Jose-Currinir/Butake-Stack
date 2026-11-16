# Cumplimiento — Stack

## Índice de requisitos

Texto completo de cada requisito en `docs/21719-gestor-entornos-requisitos.md`.

| Requisito | Tema | Origen |
|---|---|---|
| R1 a R12 | Gestor de entornos `.env`: Llavero, secreto por defecto, autenticación, Producción, escritura segura, sin fugas, auditoría, importar, compartir, borrado, incidentes, pruebas | Primera corrida, 2026-11-12 |
| R13 | Mover desde la Bóveda a Entornos o Claves SSH sin exponer | Revisión 2026-11-13 (P-21) |
| R14 | Registros de procesos sin valores | Solo en el documento de requisitos |
| R15 | Importar contraseñas de un respaldo sin exponerlas | Revisión 2026-11-14 (P-33) |
| R16 | Dirección pública fija sin exponer credenciales ni datos | Revisión 2026-11-14 (P-35) |
| R17 | Cuentas de Google Cloud sin credenciales | Revisión 2026-11-14 (P-36) |
| R18 | Git sin guardar datos de terceros ni credenciales | Revisión 2026-11-14 (G-1) |
| R19 | Fichas de GitHub y Bitbucket solo en el Llavero | Revisión 2026-11-14 (G-4) |
| R20 | Importación propuesta por un enlace sin acceso por sí sola | Revisión 2026-11-14 (P-38) |
| R21 | Resumen de importación sin contenido y material sensible sin leer | Revisión 2026-11-14 (P-40) |
| R22 | Renombrar o mover un proyecto sin secretos huérfanos ni copias | Revisión 2026-11-14 (P-41) |
| R23 | Skills: texto del usuario solo en la carpeta de Stack, enlaces solo hacia las carpetas de las IA bajo el HOME | Revisión 2026-11-16 (herramienta Skills) |

Las revisiones siguen en orden cronológico, de la más antigua a la más nueva.

## Corrida 2026-11-12 (primera)

**Corrida:** 2026-11-12 (primera) · **Commit:** 030f395 · **Marco:** Ley 21.719 · **Alcance:** gestor de
entornos `.env` por sitio, revisado **antes de implementarlo**.

## Postura
- Butake SpA no es responsable ni encargado de los datos que maneja esta función: todo queda en el Mac
  del usuario. No corresponden RAT, política, DPA ni consentimiento del producto para esta función.
- La función guarda **credenciales que abren sistemas con datos personales** (incluso de salud), así que
  es una **medida de seguridad** del responsable (Arts. 3 f, 14 quáter, 14 quinquies).
- **EIPD no obligatoria** (test del Art. 15 ter negativo). Sin transferencias internacionales.
- Puntaje de diseño: 0,30. Es esperable: los controles quedan en "falta" hasta implementarlos; la próxima
  corrida, tras la implementación, debe llevarlos a "cumple".

## Requisitos para publicar (R1 a R12)
Ver `docs/21719-gestor-entornos-requisitos.md`: secretos sólo en el Llavero y sólo en este dispositivo;
secreto por defecto; Touch ID para revelar, copiar o activar Producción; Producción bloqueada por
defecto y sin colas automáticas; `.env` atómico con permisos 600 y obligatorio en `.gitignore`; el motor
nunca imprime valores; auditoría local sin valores; importación sin copias en claro; exportar sin
secretos; borrado completo; procedimiento de incidentes; pruebas automáticas.

## Cambios vs última corrida (2026-11-12, diseño)
- **Avance:** los 10 controles quedan en «cumple» tras implementar R1 a R12. Puntaje 0,30 → 1,00.
- **Hallazgo corregido durante la implementación:** la autenticación reutilizaba un desbloqueo reciente
  del Mac con Touch ID (`touchIDAuthenticationAllowableReuseDuration`) y aprobaba sin preguntar.
  Ahora no se reutiliza, y Producción pide autenticación nueva cada vez (R3, R4).
- **Verificado con datos ficticios:** importar, crear (copia con secretos), activar, volver a Local
  (`.env` idéntico al original), permisos 600, `.env` ignorado por Git, auditoría sin valores,
  Producción bloqueada sin confirmación. El aviso de Touch ID al activar Producción apareció; la
  prueba de cancelarlo debe repetirse con la corrección.
- **Sin drift.**

## Revisión 2026-11-12 — backends KMP y bases en el PostgreSQL de Stack
- **Variables del entorno activo al backend KMP:** el daemon lee el `.env` del sitio sólo en memoria al
  arrancar el proceso; no lo copia ni lo registra, y el estado que recibe la app elimina el entorno de
  los procesos. Cumple R6 (el motor nunca imprime valores).
- **Crear base en PostgreSQL de Stack:** dos roles por base. El de la app sin superusuario, sin
  `BYPASSRLS` ni `CREATEROLE` (el RLS del proyecto siempre aplica); el de migración, dueño del esquema,
  con `BYPASSRLS` y `CREATEROLE` pero nunca superusuario. Contraseñas aleatorias de 192 bits generadas en
  el Mac; el SQL viaja por la entrada estándar de `psql`, no por argumentos (no aparecen en la lista de
  procesos); en la app pasan como secretos y se guardan en el Llavero al guardar el entorno (R1, R2).
- Sin datos personales nuevos ni transferencias: la base vive en el Mac del usuario. La postura no cambia.

## Revisión 2026-11-12 — «Mi entorno» (exportar y restaurar)
- El archivo exportado lleva perfiles, versiones, herramientas, sitios (ruta, dominio, origen Git sin
  usuario ni contraseña), carpetas y entornos **sin valores secretos** (los secretos siguen sólo en el
  Llavero, R1). Las claves no secretas de los entornos sí viajan: pueden contener datos de
  configuración, por eso el archivo se guarda con permisos 600 y el usuario elige dónde.
- Restaurar es un plan que el usuario revisa; descargas desde fuentes oficiales verificadas; sitios
  apagados; entornos nunca reemplazan a los existentes; clonar usa el acceso Git propio del usuario,
  sin preguntas interactivas, y sólo dentro de su carpeta personal.
- Sin datos nuevos hacia terceros: el archivo no sale del Mac salvo que el usuario lo copie.

## Cambios (2026-11-12, tarde)
- **R9 revisado a pedido del titular:** se permite descargar `.env.<entorno>` con valores reales,
  con autenticación, permisos 600, verificación de `.gitignore` y auditoría. Prueba automática en
  `engine/src/web/projects/envs/tests.rs`. Los controles siguen en «cumple».

## Revisión 2026-11-13 — Bóveda y Entornos enlazados (P-21)
- **Enlace app de la Bóveda ↔ proyecto:** campo opcional `project` (id del proyecto) dentro del índice
  cifrado y del `.butakevault` cifrado; nunca en `vault.json`, encabezados ni registros. El Resumen del
  proyecto lista nombre, tipo, entorno y vencimiento **sin valores**, solo con la Bóveda ya desbloqueada;
  bloqueada muestra «Desbloquear…» (acción del usuario) y no revela nombres; nunca se desbloquea sola.
- **Mover secretos entre almacenes locales** (R13 nuevo): un `.env` de la Bóveda a Entornos y una clave
  SSH a Claves SSH. Acción explícita con vista previa de **solo nombres**, confirmación y presencia nueva
  (Touch ID o contraseña). Valores del blob descifrado en memoria al Llavero de Entornos; el motor solo
  recibe nombres (`envMergeSecrets`) y audita «mover» por clave sin valores (R7). Si falla, el Llavero
  vuelve a su estado. Se verifica antes de informar éxito y **solo se ofrece** eliminar el original.
  La clave SSH pasa por una copia 0600 de corta vida en el `tmp/` 0700 de la Bóveda, borrada al terminar.
- **Nada sale del Mac**, sin datos nuevos ni terceros: la postura no cambia (medida de seguridad del
  responsable; EIPD no obligatoria). Prueba automática con valor centinela: tras mover, ningún archivo del
  almacén de Stack ni de la Bóveda lo contiene (`native/Tests/ButakeStackTests/VaultLinkTests.swift`).

## Revisión 2026-11-14 — Bóveda: importar un respaldo real y «Firma» (P-33)
- **Lectura de contraseñas desde archivos del respaldo** (R15 nuevo): al importar una carpeta, `X.p12.pass`,
  `CREDENTIALS.txt`, `fastlane.env` y archivos de un valor (`FIREBASE_APP_ID.txt`) se asocian a su archivo y
  su contenido se lee **sólo al importar**, en memoria, directo a los campos secretos del elemento (índice
  cifrado AES-GCM). La vista previa guarda rutas y nombres de campo, nunca valores, y muestra «Contraseña
  asociada»; los mensajes de error son textos fijos; la auditoría sigue con ids. Lo que no tiene dueño seguro
  sólo se propone y no se lee sin la marca del usuario. El origen sólo se lee.
- **Minimización:** histórico, archivados, respaldos, volcados (`.dump`, `.sql`…) y `.env` quedan sin marcar
  por defecto (los `.env` no entran: van a Entornos); el mismo archivo en varias carpetas entra una vez.
- **«Firma»** cruza nombres, fechas, paquetes y huellas públicas (SHA-1 de certificados, que no son
  secretos); el App ID de Firebase se compara sin mostrarse. Leer un llavero usa el JDK del sistema si Stack
  no tiene uno, con la contraseña por variable de entorno (`-storepass:env`), nunca en argumentos.
- Sin datos personales nuevos ni envíos fuera del Mac: la postura no cambia (EIPD no obligatoria). Prueba
  automática con contraseñas centinela en un respaldo ficticio: ninguna aparece en la vista previa, en
  «Firma», en el registro de accesos ni en archivo alguno de la bóveda
  (`native/Tests/ButakeStackTests/VaultBackupTests.swift`).

## Revisión 2026-11-14 — Dirección pública fija por proyecto (P-35)
- **Túnel con nombre por proyecto** (R16 nuevo): una dirección en un dominio del usuario para que
  funcionen el ingreso con Google y los enlaces absolutos. Conectar (`cloudflared tunnel login`) es
  un paso del usuario en el navegador; Stack solo comprueba que el certificado existe, sin leerlo.
  Las credenciales de cada túnel quedan en `tunnels/` (0600), fuera de la exportación del entorno, y
  nunca en registros, respuestas ni la interfaz: los fallos de `cloudflared` son códigos fijos.
- **Exposición controlada:** compartir pide confirmación y advierte que cualquiera con la dirección
  entra; vive solo en memoria del daemon (reiniciar o detener el proyecto deja de compartir) y la
  barra lateral marca el proyecto expuesto. Es el mismo riesgo que la dirección temporal, ahora con
  nombre estable: no compartir datos reales.
- **Orígenes de Google:** Stack solo muestra el origen exacto y abre la consola; no lo configura.
- Sin datos personales nuevos en Stack; el tráfico pasa por Cloudflare solo mientras el usuario
  comparte (decisión suya, como con la dirección temporal). EIPD no obligatoria. Prueba automática
  con una credencial centinela de un `cloudflared` falso: no aparece en el estado, las respuestas
  ni el almacén tras quitar (`engine/src/web/net/tunnels.rs`).

## Revisión 2026-11-14 — Cuentas de Google Cloud (P-36)
- **Cuentas de gcloud sin credenciales** (R17 nuevo): la herramienta Google Cloud lista las cuentas que gcloud
  ya tiene (`auth list`) y los proyectos de cada una (`projects list --account=…`). Nunca lee ni copia los
  archivos de credenciales de gcloud, no ejecuta comandos que impriman fichas, no crea ni descarga claves de
  cuentas de servicio (siguen en la Bóveda) y no cambia IAM, APIs, recursos ni la configuración activa de
  gcloud: iniciar sesión es `auth login --no-activate` en una consola de la Terminal, con el navegador y la
  contraseña del usuario; cerrar sesión se confirma y no se ofrece para la cuenta activa.
- **Datos:** el enlace de un proyecto guarda su correo de Google y el ID del proyecto (no secretos) en la
  configuración local del proyecto; los procesos y consolas del proyecto los reciben como variables. La lista
  de proyectos se guarda 10 minutos solo en memoria de la app. Abrir la consola web lleva el correo como
  `authuser` al propio Google, a pedido del usuario. Nada nuevo sale del Mac por Stack: la postura no cambia
  (EIPD no obligatoria).
- **Pruebas** con un gcloud falso y cuentas inventadas (`engine/src/gcp/testdata/gcloud`): ningún flujo
  cambia la configuración activa, ninguna llamada pide fichas ni usa `config`, y una consola del proyecto
  recibe las variables (`engine/src/gcp/mod.rs`, `native/Tests/ButakeStackTests/GCPTests.swift`).

## Revisión 2026-11-14 — Herramienta Git (G-1)
- **Git sin guardar datos de terceros ni credenciales** (R18 nuevo): la herramienta Git (motor de Butake Git
  dentro de Stack) lee de cada repositorio nombres y correos de autores de commits, que son datos personales
  de terceros, solo para responder a la app: no se guardan en el almacén, registros ni archivos de Stack.
- **Datos:** solo rutas de repositorios agregados y recientes y sus fechas (`config/git/repositories.json`,
  0600), borradas con «Eliminar datos». Sin tokens ni contraseñas: Git usa el agente SSH y los gestores de
  credenciales del usuario; las URL de remotos salen sin credenciales y los detalles de error pasan por el
  filtro de R14. Nada nuevo sale del Mac por Stack (las operaciones de red son las de Git a los remotos que el
  usuario configuró): la postura no cambia (EIPD no obligatoria).
- **Pruebas** con repositorios temporales y configuración de Git aislada (`engine/src/git/tests/`).

## Revisión 2026-11-14 — Git con GitHub y Bitbucket Cloud (G-4)
- **Fichas de acceso de proveedores solo en el Llavero** (R19 nuevo): la herramienta Git se conecta a GitHub y
  Bitbucket Cloud con una ficha de acceso que el usuario crea en el sitio del proveedor con los permisos mínimos
  que Stack le muestra. Se guarda solo después de que el proveedor la acepta, en un ítem del Llavero por cuenta
  (solo este dispositivo, sin sincronizar; servicio `cl.butake.stack.git.accounts`); sus atributos guardan quién
  es la cuenta (usuario, nombre y, en Bitbucket, el correo con que se autentica), nunca la ficha. Se lee de forma
  perezosa (al primer pedido a la API, una vez por sesión) y la usa solo la app, en la cabecera `Authorization`
  de pedidos HTTPS al anfitrión de la API del propio proveedor: nunca va al motor, a Git, a argumentos de
  procesos, archivos, registros, respuestas ni a la interfaz (no se muestra ni se copia). Git sigue usando las
  llaves SSH y gestores de credenciales del usuario (R18).
- **Datos nuevos:** se muestran en el momento (no se guardan) pull requests, comentarios, revisiones y
  comprobaciones del proveedor, con nombres de usuario de terceros. Lo único que Stack escribe es la protección
  de la rama principal leída del proveedor (`butake.remoteProtectMain` en la configuración local del
  repositorio). Crear un repositorio (privado por defecto), un pull request, aprobar o combinar siempre se
  confirma. Los datos ya están en el proveedor que eligió el usuario; Stack solo los consulta a su pedido: la
  postura no cambia (EIPD no obligatoria).
- **Pruebas** contra un servidor falso en 127.0.0.1 con cuentas y fichas inventadas y un Llavero en memoria; una
  ficha centinela no aparece en el almacén de Stack, los repositorios, las respuestas del motor, las
  preferencias, los textos de la interfaz ni los errores, y solo viaja en la cabecera `Authorization`
  (`native/Tests/ButakeStackTests/GitHostingTests.swift`).

## Revisión 2026-11-14 — Bóveda: importación preparada por un enlace (P-38)
- **Enlace que solo propone** (R20 nuevo; no se amplía R15 porque trata del origen de la solicitud, no de
  las contraseñas): `butakestack://vault/import?path=<carpeta>` abre la vista previa de «Importar carpeta…»
  con las carpetas ya elegidas. Nunca importa ni desbloquea; con la Bóveda bloqueada guarda solo las rutas
  en memoria y no lee ni muestra nada del respaldo hasta que el usuario desbloquea por el camino normal.
- **Contra enlaces maliciosos:** rutas absolutas, sin `..`, existentes y carpetas, o se rechaza el enlace
  entero con aviso; la hoja dice «Carpeta propuesta por un enlace: revisa antes de importar» y lista las
  rutas; la confirmación sigue siendo el botón del usuario. Con la herramienta apagada no se guarda nada.
- Sin datos personales nuevos ni envíos fuera del Mac: la postura no cambia (EIPD no obligatoria). Pruebas
  con un respaldo inventado y llaves en memoria (`native/Tests/ButakeStackTests/VaultImportLinkTests.swift`).

## Revisión 2026-11-14 — Renombrar y mover un proyecto (P-41)
- **Sin secretos huérfanos ni copias** (R22 nuevo; no se amplía R14 porque trata de dónde viven los
  secretos al cambiar el id, no de los registros): el renombre cambia en un solo paso, con reversión,
  todo lo que cuelga del id o de la carpeta; el motor no lee el Llavero y la app mueve los ítems de
  Entornos copiándolos tal cual, verificando y borrando los viejos solo con el renombre hecho. Si el
  Llavero no responde, no se renombra.
- **Desde la línea de comandos:** `renames.json` guarda solo ids y pasos pendientes; la app los
  completa al abrirse y al desbloquear la Bóveda. Cambiar la carpeta no copia el `.env`.
- Sin datos personales nuevos ni envíos fuera del Mac: la postura no cambia (EIPD no obligatoria).
  Pruebas: `engine/src/web/projects/rename_tests.rs`, `engine/tests/cli.rs` y
  `native/Tests/ButakeStackTests/ProjectRenameTests.swift` (Llavero en memoria).

## Revisión 2026-11-14 — Bóveda: importación clara (P-40)
- **Resumen sin contenido y material sensible sin leer** (R21 nuevo; no se amplía R15, que trata de las
  contraseñas asociadas, ni R20, que trata del enlace): volcados de bases (con sus `*.sha256`) y carpetas
  `_CUARENTENA*` se listan solo por nombre, no se leen ni se ofrecen para importar; una cuarentena nunca crea
  una app ni un servicio. El resumen por categoría guarda solo rutas relativas y cuentas, dentro del índice
  cifrado («Última importación»).
- Sin datos personales nuevos ni envíos fuera del Mac: la postura no cambia (EIPD no obligatoria). Pruebas con
  un respaldo inventado y llaves en memoria (`native/Tests/ButakeStackTests/VaultImportClarityTests.swift`).

## Revisión 2026-11-16 — Git por HTTPS con la ficha de la cuenta y servidores SSH conocidos
- **La ficha también autentica a Git, solo con su proveedor** (R19 ampliado; R18 ajustado): conectar la cuenta
  permitía listar los repositorios pero no clonarlos por HTTPS, porque la ficha no llegaba a Git. Ahora la app
  la entrega al motor con cada transferencia por HTTPS (clonar, traer, bajar, subir, publicar) cuyo remoto es
  una dirección `https://` de GitHub o Bitbucket Cloud con cuenta conectada. El motor la tiene en memoria
  durante ese comando y se la da a Git por un ayudante askpass (socket Unix en carpeta 0700, ficha de un solo
  uso, mismo usuario), que responde solo a la pregunta por el origen del proveedor. Con ese comando los
  gestores de credenciales de Git quedan apagados: nada la guarda. No va a la dirección del remoto, a la
  configuración de Git, a argumentos, variables, archivos, registros, respuestas ni a la interfaz.
- **Permisos de la ficha:** los mínimos que Stack muestra incluyen ahora leer y escribir repositorios
  (GitHub «Contents: Read and write»; Bitbucket `read:repository:bitbucket` y `write:repository:bitbucket`).
  Una ficha anterior, de solo lectura, sirve para clonar y traer; para subir hay que crear otra.
- **Servidores SSH conocidos:** al clonar por SSH, Stack agrega el servidor a `~/.ssh/known_hosts` solo tras
  mostrar sus huellas y con la confirmación del usuario; para GitHub y Bitbucket las compara con las que
  publica cada proveedor y rechaza cualquier otra. No lee claves privadas.
- Sin datos personales nuevos; lo único que sale del Mac es la autenticación de Git ante el proveedor que el
  usuario conectó: la postura no cambia (EIPD no obligatoria). Pruebas: `engine/tests/git_credentials.rs`
  (servidor local y ficha centinela), `engine/src/git/tests/access.rs` y
  `native/Tests/ButakeStackTests/GitCloneAccessTests.swift`.

## Revisión 2026-11-16 — Herramienta Skills
- **Skills como texto del usuario, sin salir de Stack ni tocar lo ajeno** (R23 nuevo; ningún requisito anterior
  trata de enlaces dentro de carpetas de otros programas): las skills (instrucciones en texto) viven en
  `skills/` de la carpeta de datos de Stack, con su índice (0600) y una papelera de 30 días. Solo
  `skillsRead` y `skillsExport` devuelven su texto; nada se registra. Las IA (Claude, Codex, Gemini) reciben
  enlaces simbólicos a la copia única, solo bajo el HOME canonicalizado; solo se quitan enlaces que resuelven
  a la carpeta `skills/` de Stack y cada cambio se planifica, se muestra y se confirma. ChatGPT solo recibe
  texto exportado, copiado por el usuario.
- **Revisión 2026-11-16 (A1, carpeta de Codex):** Codex pasa a `~/.agents/skills`, carpeta compartida entre IA:
  lo que otras herramientas pusieron allí es conflicto y no se toca. Los enlaces de Stack que quedaron en
  `~/.codex/skills` se mueven solo por el par plan/`confirmed` (`migrate`), con las rutas exactas, y solo si
  resuelven a `skills/` de Stack; el resto de esa carpeta no se lista ni se toca. La salud (`moved_folder`) lo
  ofrece. Sin datos nuevos: la postura no cambia. Pruebas: `engine/src/skills/tests/migration.rs`.
- **Revisión 2026-11-16 (A2, Kiro):** Kiro entra como IA incluida solo de exportación (sin carpeta): el escáner
  de Kiro Crew descarta un enlace de `~/.kiro/crew/skills` que resuelve fuera de sus raíces, y la regla es
  nunca copiar. Stack no lee ni escribe `~/.kiro` ni los ajustes de otra IA (`skills.extra_paths` es del
  usuario). Sin datos nuevos: la postura no cambia. Pruebas: `engine/src/skills/tests/links.rs`
  (`kiro_is_export_only_and_never_touches_its_folder`).
- **Revisión 2026-11-16 (A4, rutas dentro de una skill):** la salud (`agent_path`) lee `SKILL.md` y los archivos
  de texto de apoyo de cada skill (regulares, sin seguir enlaces, sin binarios, con tope de tamaño y
  cantidad) solo para hallar rutas a la carpeta de una IA a la que la skill no está enlazada. No reescribe ni
  devuelve el texto: el hallazgo lleva solo skill, IA y carpeta. R23 ampliado. Sin datos nuevos: la postura no
  cambia. Pruebas: `engine/src/skills/tests/health_export.rs`
  (`health_reports_paths_to_unlinked_agents`, `health_agent_path_counts_only_own_id_and_text_files`).
- Sin datos personales nuevos que Stack procese por su cuenta ni envíos fuera del Mac: la postura no cambia
  (EIPD no obligatoria). Pruebas con HOME y carpeta de datos temporales y skills inventadas:
  `engine/src/skills/tests/` (`skills.rs`, `links.rs`, `trash_groups.rs`, `health_export.rs`, `dispatch.rs`).

## Pendiente fuera del código
- RUT de Butake SpA (sólo para el estado; no afecta los requisitos).
- Recomendación organizativa: credenciales de Producción de sólo lectura en Macs de desarrollo.

## Próxima corrida
Al terminar la implementación y antes del release que la publique.

---
*No constituye asesoría legal. Borrador fundado en la Ley 21.719 para cumplir sin abogado.*
