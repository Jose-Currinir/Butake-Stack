# Registros

Un solo lugar para leer lo que escriben los procesos supervisados: el servidor web, cada PHP-FPM, los
servicios, los procesos de cada proyecto y lo que se comparte, más el registro de accesos de la Bóveda.

Registros **es de la base**, no del catálogo: siempre aparece al final de Herramientas en la barra
lateral, no se activa ni se apaga y no tiene `plugin_disabled`.

- Motor: `engine/src/daemon/logs.rs` (escritura y rotación), `engine/src/daemon/redact.rs` (filtro) y
  el supervisor (`daemon/supervisor.rs`).
- App: `native/Sources/ButakeStack/Tools/Logs/`.

## Qué hace

- Lista de fuentes agrupadas por origen: servidor web (`stack.caddy`), PHP (`stack.php-*`), servicios
  (`stack.*`), proyectos (`<proyecto>.<proceso>`, `share.<proyecto>`) y Bóveda (`vault.access`, si la
  Bóveda está activa y existe).
- Lectura en vivo con búsqueda, filtro por nivel, pausa y «Borrar» (solo cambian lo que está en
  pantalla, no el archivo).
- «Ver registros» de un proyecto o servicio lleva aquí ya filtrado.

## Métodos del motor

No tiene métodos propios del CLI. La app se suscribe con `butake-stack watch-logs <proceso>`, que
entrega del daemon las líneas de ese proceso en JSON por líneas; la suscripción se cierra al salir de
la vista. El estado de los procesos llega con `watch-status`.

## Datos que guarda

| Qué | Dónde |
|---|---|
| Salida de cada proceso | `logs/<proceso>.log` (0600, sin seguir enlaces) |
| Rotación | Al pasar de 5 MiB: `.log.1`, `.log.2`, `.log.3` |
| Últimas líneas en memoria del daemon | 2.000 por proceso; cada línea hasta 8 KiB |

Otros registros del almacén que no pasan por esta vista: `logs/env-audit.log` (auditoría de Entornos),
`logs/task-<id>.log`, `logs/env-<id>.log` y `logs/python-<id>.log`.

## Seguridad

- Cada línea pasa por el filtro de valores secretos antes de llegar al archivo o a la vista: la línea se
  conserva y cada valor sensible se reemplaza por `[oculto]` (R14). Criterio completo en
  [operations.md](../operations.md#registros).
- Se quitan los caracteres de control salvo el tabulador.
- No hay telemetría: los registros no salen del Mac.

## Enlaces

- `butakestack://tool/logs`: abre Registros (siempre disponible).
- `butakestack://tool/logs?source=<proceso>`: abre esa fuente.
- `butakestack://tool/logs?origin=<web|php|services|projects|vault>`: filtra por origen.
- `butakestack://service/logs`: alias antiguo.

## Límites conocidos

- La vista lee del daemon: con el supervisor detenido no hay líneas nuevas.
- Lo que un proceso escribió fuera de su salida estándar y de error (sus propios archivos de registro)
  no aparece.
