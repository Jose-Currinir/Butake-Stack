# Google Cloud

Usa las cuentas que gcloud ya tiene en el Mac: lista cuentas de usuario y de servicio (con la activa de
gcloud marcada), los proyectos de cada una, accesos a la consola web, y el enlace de cada proyecto de
Stack con una cuenta y un proyecto de Google.

- Motor: `engine/src/gcp/` (`accounts.rs`, `cli.rs`; gcloud falso de pruebas en `gcp/testdata/gcloud`);
  gcloud corre con `core/cli_tool.rs`, común con AWS.
- App: `native/Sources/ButakeStack/Google/` (archivos `GCP*`); la lista de cuentas, sus filas y la cabecera
  de la tarjeta son las de `Shared/Cloud/`.
- Id del catálogo: `gcp`. Requiere gcloud, instalado con el instalador de Google (no está en
  Utilidades).

## Cómo se activa

Ajustes › Herramientas › Google Cloud. Aparece en el bloque «Nube» de la barra lateral. Apagada, cada
`gcp*` responde `plugin_disabled`. Sin gcloud, la página lo dice (`gcp_cli_missing`).

## Qué hace

- Cuentas (`gcloud auth list`) y proyectos de cada una (`gcloud projects list --account=…`, guardados
  10 minutos en memoria de la app), con accesos a la consola web, Credenciales, Firebase y Facturación
  de cada proyecto.
- «Iniciar sesión…» abre `gcloud auth login --no-activate` en una pestaña de la Terminal de Stack (el
  navegador y la contraseña son del usuario). Necesita la Terminal encendida; si no, lleva a su fila en
  Ajustes.
- «Cerrar sesión…» (`gcloud auth revoke`) se confirma y no se ofrece para la cuenta activa.
- Enlace por proyecto: campo `gcp` del proyecto (`{"account": "<correo>", "project": "<id>"}`). Un
  proyecto de varias partes puede fijar el suyo en `groups.json`; cada parte lo hereda salvo que tenga
  uno propio. Ver [proyectos.md](../proyectos.md#enlace-de-google-cloud).

## Métodos del motor

| Método | Qué hace |
|---|---|
| `gcpAccounts` | gcloud encontrado o no, sus cuentas y qué proyectos de Stack usan cada una |
| `gcpProjects {account}` | Proyectos de Google de una cuenta (60 s como máximo) |
| `gcpRevoke {account, confirmed}` | Cierra la sesión de una cuenta que no es la activa (30 s) |
| `gcpLink {id, account, project}`, `gcpUnlink {id}` | Enlace de un proyecto de Stack |
| `gcpLinkGroup {id, account, project}`, `gcpUnlinkGroup {id}` | Enlace de un proyecto de varias partes |

## Datos que guarda

| Qué | Dónde |
|---|---|
| Enlace de un proyecto | `projects/<id>.json`, campo `gcp` (correo e id del proyecto; no son secretos) |
| Enlace de un proyecto de varias partes | `groups.json`, campo `gcp` |
| Procesos de gcloud en curso | `gcp-runs/` |

Nada en el Llavero: Stack no guarda credenciales de Google.

## Seguridad (R17)

- Los procesos del proyecto y «Abrir consola aquí» reciben `CLOUDSDK_CORE_ACCOUNT`,
  `CLOUDSDK_CORE_PROJECT` y `GOOGLE_CLOUD_PROJECT`. El motor las agrega al armar cada proceso y en
  `siteShellEnvironment`, nunca en `env` ni en el registro del proyecto; una de ellas escrita a mano en
  `env` gana sobre el enlace.
- Stack nunca cambia la configuración activa de gcloud ni escribe en su carpeta, no lee ni copia sus
  archivos de credenciales, no ejecuta comandos que impriman fichas, no crea ni descarga claves de
  cuentas de servicio (siguen en la Bóveda) y no cambia permisos, APIs ni recursos.
- gcloud corre sin shell, con argumentos separados, entorno mínimo y límite de tiempo; su salida nunca
  se devuelve: se convierte en un código fijo (`gcp_*`).
- Abrir la consola web lleva el correo como `authuser` al propio Google, a pedido del usuario.

## Enlaces

- `butakestack://tool/gcp`: abre la herramienta.

## Límites conocidos

- No configura los orígenes autorizados de un cliente OAuth: la dirección fija de un proyecto solo
  muestra el origen exacto y abre la página de credenciales.
- Pruebas en la app: `GCPTests.swift` y `KeysAndCloudTests.swift` (la lista común de cuentas).
