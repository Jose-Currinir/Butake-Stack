# Bóveda

Guarda cifrado lo que se usa para firmar y publicar cada app: llaveros de Android, certificados y
perfiles de iOS, claves de App Store Connect y APNs, archivos de Firebase, cuentas de servicio, tokens
y notas. Organiza por apps y servicios, cruza lo guardado en «Firma» y se enlaza con proyectos.

- App: `native/Sources/ButakeStack/Vault/`. **El motor no lee ni escribe la Bóveda**: no hay métodos
  `vault*`.
- Id del catálogo: `vault`. Requiere el Llavero.
- Formato en disco, clave maestra, `.butakevault`, carpeta en claro, respaldo por plataforma, «Firma»
  y metadatos: [boveda-formato.md](../boveda-formato.md).

Bóveda y Entornos son almacenes distintos y enlazados: Entornos guarda lo que un proyecto necesita
para correr (su `.env`); la Bóveda, lo que se necesita para firmar y publicar. Ver
[decisiones.md](../decisiones.md).

## Cómo se activa

Ajustes › Herramientas › Bóveda. Viene encendida y registrada siempre. Desactivarla nunca borra
nada: sus datos solo se borran desde la propia Bóveda (`pluginRemove` con `deleteData` responde
`vault_data_kept`), y quitarla la deja registrada y apagada para que no vuelva a encenderse sola.

## Qué hace

- Crear, desbloquear (Touch ID o contraseña del Mac) y bloquear; se bloquea sola tras 5 minutos sin
  uso, al dormir o al bloquear la pantalla.
- Apps y servicios (`_SERVICIOS`), con cuentas por servicio; elementos con campos, archivos y notas.
- Revelar y copiar con presencia; exportar e importar `.butakevault`; descargar e importar una carpeta
  en claro.
- «Firma» por app y entorno, con vencimientos.
- Enlace de una app con un proyecto o con un proyecto de varias partes (`group:<id>`, que heredan sus
  partes). El Resumen del proyecto lista lo enlazado sin valores, solo con la Bóveda desbloqueada.
- Mover un `.env` guardado a Entornos o una clave SSH a Ajustes › Claves SSH (R13).
- Registro de accesos (`access.log`, solo ids).

### Qué entra al importar una carpeta

«Importar carpeta…» dice antes de importar, y guarda después, qué entró y qué no (R21):

- **Sin contenedores vacíos.** Una carpeta sin nada que importar (por ejemplo `_SERVICIOS/aws` con solo
  un `README.md`) no crea app ni servicio; su README queda como «Sin nada que importar». Las carpetas
  `_CUARENTENA*` nunca crean nada.
- **Un servicio con sus cuentas.** Las subcarpetas de un servicio (`cloudflare/<cuenta>`,
  `apple-signing/developer-id`) son cuentas de ese servicio, con una sección y notas propias. Descargar
  la Bóveda vuelve a escribir cada cuenta en su subcarpeta. Una cuenta guardada antes como servicio con
  ruta se reúne en su servicio al volver a importar, sin duplicar (se compara la huella).
- **Resumen por categoría**, en la vista previa y en ⋯ › «Última importación…»: Importado, Notas tomadas
  de README, Histórico, Volcados, archivos `.env` (con «Abrir Entornos», que solo navega), En
  cuarentena, Duplicados y Sin reconocer (tipo desconocido, enlaces, más de 20 MB, carpetas que no son
  app ni `_SERVICIOS`). Histórico y sin reconocer se pueden marcar para incluir. Volcados y cuarentena
  no se leen ni se ofrecen. Se guardan solo rutas relativas y cuentas, en el índice cifrado.
- **⋯ › «Quitar contenedores vacíos…»** quita, tras confirmar, las apps y servicios sin elementos. Nunca
  borra un elemento.

## Métodos del motor

Ninguno. La Bóveda vive entera en la app. Para mover datos usa métodos de la base: `envMergeSecrets`
(un `.env` a Entornos) y `sshKeyImport` (una clave a Claves SSH).

## Datos que guarda

| Qué | Dónde |
|---|---|
| Índice cifrado, archivos cifrados, registro de accesos | `vault/` (0700; archivos 0600) |
| Copias de corta vida para `keytool` y para mover claves | `vault/tmp/` (se borran al terminar) |
| Clave maestra | Llavero, `cl.butake.stack.vault`, cuenta `master/<keyId>` (`.qa` con un almacén de pruebas) |
| Propuesta de importación por enlace | Solo en memoria |

## Seguridad

- AES-256-GCM con contexto autenticado por índice y por archivo; clave maestra solo de este dispositivo
  y sin sincronizar.
- Revelar y copiar piden presencia (vale 60 s); guardar un archivo, exportar y descargar la piden
  siempre. Lo copiado se marca como oculto y se borra del portapapeles a los 30 s.
- Las contraseñas que un respaldo guarda junto a su archivo se leen solo al importar, en memoria (R15).
- La exportación de la configuración de Stack nunca lleva nada de la Bóveda.

## Enlaces

- `butakestack://vault` o `butakestack://tool/vault`: abre la herramienta.
- `butakestack://vault/import?path=<carpeta absoluta>` (R20): deja lista la importación para que el
  usuario revise y confirme. `path` se repite para varias carpetas (hasta 8); cada valor va codificado
  como componente de URL (el espacio es `%20`; un `+` se toma literal):

  ```
  butakestack://vault/import?path=/Users/ana/Respaldo/Demo%20(cl.demo.app)&path=/Users/ana/Respaldo/_SERVICIOS
  ```

  - Presenta la misma vista previa de «Importar carpeta…» con esas carpetas ya elegidas y el aviso
    «Carpeta propuesta por un enlace: revisa antes de importar».
  - Bloqueada (o sin crear), solo guarda las rutas en memoria: no lee ni muestra nada; la pantalla dice
    cuántas carpetas esperan, nunca cuáles, y ofrece «Descartar propuesta». El enlace nunca desbloquea
    ni importa.
  - Rutas absolutas, sin `..`, existentes y carpetas; una inválida rechaza el enlace entero con aviso.
    No reemplaza una hoja abierta. Con la herramienta apagada abre Ajustes › Herramientas y no guarda
    nada.

## Límites conocidos

- El Llavero de protección de datos no está disponible porque la app se firma sin derechos: la clave
  maestra va al Llavero de inicio de sesión y la app pide presencia antes de leerla
  ([boveda-formato.md](../boveda-formato.md#clave-maestra)).
- Los tipos `envFile` y `sshKey` se leen, pero la app ya no los crea.
- «Firma» de un llavero de Android necesita un JDK (el de Stack o el del sistema).
