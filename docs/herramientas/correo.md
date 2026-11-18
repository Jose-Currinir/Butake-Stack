# Correo

Servidor SMTP de captura: recibe todo lo que envían los proyectos y lo guarda en el Mac en lugar de
entregarlo. Nada sale del Mac.

- Motor: `engine/src/web/tools/mail.rs` (servidor y lectura) y el receptor dentro del daemon
  (`engine/src/daemon/mod.rs`).
- App: `native/Sources/ButakeStack/Tools/Mail/`.
- Id del catálogo: `mail`. Requiere el daemon (supervisor).

## Cómo se activa

Ajustes › Herramientas › Correo. Su estado no vive en `config/plugins.json` sino en la sección `mail` de
`stack.json`, que también lee el daemon. Activar pide al daemon que recargue y abra el receptor en
`127.0.0.1`; si el supervisor está detenido, se abre al iniciarlo. La vista muestra por separado si
escucha, si otro programa ocupa el puerto (y cuál) o si el supervisor está detenido. Desactivar
libera el puerto y conserva los mensajes; «Eliminar datos» los borra.

La página muestra lo que el proyecto necesita en su `.env` (`MAIL_MAILER=smtp`, `MAIL_HOST=127.0.0.1`,
`MAIL_PORT=<puerto>`, `MAIL_ENCRYPTION=null`) para copiarlo. Stack no escribe el `.env` del proyecto.

## Qué hace

- Acepta cualquier mensaje en `127.0.0.1:<puerto>` (2525 por defecto). AUTH se acepta y se descarta.
- Bandeja con la cuenta en la barra lateral; cada mensaje en texto, código HTML, cabeceras y fuente.
- Guardar un adjunto y borrar uno o todos los mensajes.
- Retención: 7 días y 500 mensajes por defecto; lo más antiguo sale primero. «Opciones…», en la barra
  de la página, cambia el puerto, los días (1 a 365) y el máximo (100 a 10.000).

## Métodos del motor

| Método | Qué hace |
|---|---|
| `pluginSetEnabled {id: "mail"}` | Enciende o apaga el receptor (escribe `stack.json` y recarga el daemon) |
| `mailChanges {known}` | Mensajes nuevos y borrados respecto de los que la app ya tiene |
| `mailGet {id}` | Un mensaje: cabeceras, texto, HTML, fuente y adjuntos |
| `mailAttachment {id, index, path}` | Guarda un adjunto donde el usuario eligió |
| `mailDelete {id}` o `{all: true}` | Borra uno o todos |
| `setMail {enabled, port, retentionDays, maxMessages}` | Cambia la configuración del receptor («Opciones…» de la página) |

El estado (`enabled`, `port`, `running`, `busy`, `count`, `retentionDays`, `maxMessages`) llega con
`stackStatus` y `watch-status`.

## Datos que guarda

| Qué | Dónde |
|---|---|
| Mensajes | `mail/` (0600) |
| Configuración | `stack.json`, sección `mail` |

## Seguridad

- Solo escucha en `127.0.0.1`. Mensajes de hasta 25 MiB, 100 destinatarios y líneas de 8 KiB.
- Las credenciales de AUTH no se guardan.
- La app muestra el HTML como texto en controles nativos: no hay vista web, ni JavaScript, ni cargas de
  red.

## Enlaces

- `butakestack://tool/mail` (y el alias `butakestack://service/mail`): abre la herramienta.

## Límites conocidos

- El HTML no se ve renderizado, solo como código.
- Pruebas: las del motor en `web/tools/mail.rs` y, en la app, `ReceiverToolsTests.swift` (decodificación,
  búsqueda, opciones y `plugin_disabled`).
