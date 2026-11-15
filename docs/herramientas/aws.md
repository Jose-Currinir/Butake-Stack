# AWS

Muestra y administra los perfiles de AWS CLI v2 del Mac: tipo de credencial (claves, sesión única,
rol, proceso externo), región, cuenta y vigencia de la sesión única; «Comprobar»
(`sts get-caller-identity`), iniciar y cerrar la sesión única, y crear, editar, renombrar, duplicar,
eliminar y marcar el predeterminado. Stack no integra ni simula servicios de AWS: solo trabaja con
los archivos y con el AWS CLI instalado.

- Motor: `engine/src/aws/` (`profiles.rs`, `edit.rs`, `ini.rs`, `cli.rs`, `helper.rs`, `keychain.rs`); AWS CLI
  corre con `core/cli_tool.rs`, común con Google Cloud.
- App: `native/Sources/ButakeStack/AWS/`; la lista de perfiles, sus filas y la cabecera de la tarjeta son
  las de `Shared/Cloud/`.
- Id del catálogo: `aws`. Requiere AWS CLI (Componentes › Utilidades) y el Llavero.

## Cómo se activa

Ajustes › Herramientas › AWS. Aparece en el bloque «Nube» de la barra lateral. Apagada, cada `aws*`
responde `plugin_disabled`. Con la herramienta encendida, la fila «AWS CLI» de Utilidades lleva a sus
perfiles.

## Archivos

Los de AWS CLI: `~/.aws/config` y `~/.aws/credentials`, o los que nombran `AWS_CONFIG_FILE` y
`AWS_SHARED_CREDENTIALS_FILE`. La sesión única se lee de `~/.aws/sso/cache/<sha1>.json` (SHA-1 del
nombre de la sesión, o de la dirección de inicio en la configuración antigua), y de ese archivo
solo se toma `expiresAt`. Con `BUTAKE_DEVTOOLS_HOME` (pruebas y QA) todo se busca en esa carpeta.

## Datos sensibles

- Ninguna respuesta del motor lleva una clave secreta ni un token: de una clave de acceso solo
  van el tipo y sus cuatro últimos caracteres. Los errores son códigos fijos (`error.aws_*`), nunca
  el texto de AWS CLI.
- Toda escritura es explícita y confirmada en la interfaz. Antes de escribir, el archivo se copia a
  `aws-backups/<config|credentials>-<fecha>.bak` (0600, se guardan los 20 últimos de cada uno) y
  luego se reemplaza de forma atómica con permisos 0600. Si el archivo es un enlace, se escribe su
  destino y el enlace se conserva.
- La edición es por líneas: cambia solo la línea de un ajuste, el encabezado de una sección o las
  líneas de la sección que se borra. Comentarios, líneas en blanco, orden, estilo (`a=b` o
  `a = b`), finales de línea y ajustes desconocidos quedan igual byte a byte.
- Una sección escrita dos veces se muestra con aviso y no se edita (AWS CLI rechaza ese archivo).
- AWS CLI se ejecuta sin shell, con argumentos separados, entorno mínimo (`HOME`, `PATH`,
  `LANG`, los dos archivos) y límite de tiempo: 30 s para «Comprobar» y «Cerrar sesión», 5 min
  para «Iniciar sesión…» (`aws_login_timeout`; la fila muestra a qué hora termina la espera).
  Las variables `AWS_*` del llamador no pasan.
- Toda espera se puede cancelar: AWS CLI corre en su propio grupo de procesos y el motor lo
  termina por ese grupo exacto (`engine/src/core/watch.rs`) cuando la app le envía SIGTERM
  («Cancelar», cambiar de perfil, salir de la página; responde `aws_cancelled`), cuando la app
  desaparece (el motor cambia de padre) o al vencer el límite. Si el motor muere sin limpiar, la
  siguiente petición de AWS recoge el grupo con el registro que dejó en `aws-runs/` (pid, grupo y
  hora de inicio; nunca por nombre).

## Claves en el Llavero (`credential_process`)

Al crear un perfil con claves se elige dónde guardarlas: en el archivo de credenciales (lo que hace
AWS CLI, por defecto) o en el Llavero. Con el Llavero:

- El motor guarda las claves (servicio `cl.butake.stack.aws`, cuenta = nombre del perfil, solo este
  dispositivo, sin sincronizar; `.qa` con un almacén de QA). Las escribe el propio motor, así que el
  Llavero confía en él para leerlas; la app no las vuelve a leer.
- `config` queda con `credential_process = "<ruta del motor>" aws-credential <perfil>`. AWS CLI
  ejecuta ese comando cuando necesita las claves; el subcomando imprime el JSON `Version 1` por la
  salida estándar (su función), nunca lo registra ni lo escribe en stderr, y solo responde si
  `config` apunta ese mismo perfil a ese subcomando.
- La ruta del motor cambia si la app se mueve. La lista marca el perfil (`missing`: el programa ya
  no está; `other`: otra copia de Stack) y «Reparar…» reescribe la línea con la ruta actual.
- Renombrar mueve el elemento del Llavero; eliminar el perfil lo elimina. Duplicar no copia claves.

Riesgos conocidos: cualquier proceso del usuario puede ejecutar el subcomando y obtener las claves
(igual que podría leer el archivo de credenciales, pero sin copia en claro en disco ni en respaldos);
una compilación sin firmar cambia de identidad al recompilarse y macOS pedirá permiso para el
Llavero; la ruta del motor solo admite letras, dígitos, `-`, `_`, `.`, espacios y `/`.

## Métodos del motor

Todos responden `plugin_disabled` con la herramienta apagada; los que escriben exigen `confirmed`.

| Método | Qué hace |
|---|---|
| `awsProfiles` | Perfiles con tipo, región, cuenta, vigencia y estado del ayudante del Llavero |
| `awsCheck` | `sts get-caller-identity` (30 s) |
| `awsSsoLogin`, `awsSsoLogout` | Inicia (5 min) o cierra la sesión única |
| `awsCreateProfile` | Crea un perfil, con las claves en el archivo o en el Llavero |
| `awsUpdateProfile` | Edita, incluido renombrar |
| `awsDuplicateProfile` | Duplica sin copiar claves |
| `awsDeleteProfile` | Elimina (y su ítem del Llavero) |
| `awsSetDefault` | El perfil pasa a llamarse `default` y el anterior toma otro nombre; nada se copia |
| `awsRepairHelper` | Reescribe la línea `credential_process` con la ruta actual del motor |

Subcomando: `butake-stack aws-credential <perfil>` (lo ejecuta AWS CLI, ver abajo).

## Datos que guarda

| Qué | Dónde |
|---|---|
| Respaldos antes de cada escritura (20 por archivo) | `aws-backups/` (0600) |
| Procesos de AWS CLI en curso (pid, grupo, hora) | `aws-runs/` |
| Claves de perfiles con Llavero | Llavero, `cl.butake.stack.aws` (`.aws.qa` en pruebas) |

Los perfiles mismos viven en los archivos de AWS CLI, no en Stack.

## Enlaces

- `butakestack://tool/aws`: abre la herramienta (apagada, Ajustes › Herramientas con su fila).

## Límites conocidos

- Los respaldos de `aws-backups/` copian el archivo de credenciales tal cual: si tenía claves en claro,
  sus respaldos también.
- No hay exportar ni importar perfiles.

## Sesión única

Con la sesión vigente la fila ofrece «Renovar sesión…» (secundaria) y «Cerrar sesión…»; vencida o
sin sesión, «Iniciar sesión…» es su acción principal. Mientras AWS CLI espera al navegador la fila
dice «Termina de iniciar sesión en el navegador…» y ofrece «Cancelar», que deja la fila como
estaba. Al terminar se vuelve a leer `expiresAt` de la caché. «Comprobar» y «Cerrar sesión»
muestran su progreso y ofrecen «Cancelar» cuando la espera pasa de dos segundos.

## Uso en proyectos

En Entornos, «Perfil de AWS» fija `AWS_PROFILE` (y `AWS_REGION` si el perfil tiene región) como
variables no secretas del entorno que se edita; se guardan con «Guardar». En Producción pide
confirmación y dice a qué cuenta entra el perfil. La ficha de cada perfil lista los proyectos y
entornos que lo usan.
