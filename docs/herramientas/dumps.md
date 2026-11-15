# Dumps

Receptor de las llamadas `dump()` de PHP (protocolo de servidor de VarDumper): muestra cada volcado
como texto, con su origen, sin ejecutar nada.

- Motor: `engine/src/web/tools/dumps.rs` y el receptor dentro del daemon (`engine/src/daemon/mod.rs`).
- App: `native/Sources/ButakeStack/Tools/Dumps/`.
- Id del catálogo: `dumps`. Requiere el daemon.

## Cómo se activa

Ajustes › Herramientas › Dumps. Como Correo, su estado vive en la sección `dumps` de `stack.json`.
Activar abre el receptor en `127.0.0.1:9912`; la vista muestra si escucha, si hay conflicto de puerto o
si el supervisor está detenido. Desactivar libera el puerto.

La página muestra lo que el proyecto necesita: `VAR_DUMPER_FORMAT=server` (y
`VAR_DUMPER_SERVER=127.0.0.1:<puerto>` si el puerto no es el de siempre).

## Qué hace

- Recibe cada línea `base64(serialize([Data, contexto]))`, la lee con un lector propio de
  `unserialize` que no instancia nada y la convierte en texto como el volcador de consola.
- Lista con búsqueda y detalle; «Borrar» vacía la lista.

## Métodos del motor

| Método | Qué hace |
|---|---|
| `pluginSetEnabled {id: "dumps"}` | Enciende o apaga el receptor |
| `dumpsClear` | Vacía la lista (pide al daemon `clearDumps`) |
| `setDumps {enabled, port}` | Cambia la configuración del receptor («Opciones…» de la página) |

La lista llega por el subcomando `butake-stack watch-dumps` (suscripción al daemon, que la app abre al
entrar a la vista y cierra al salir).

## Datos que guarda

Ninguno en disco: los volcados viven en la memoria del daemon (los 300 más nuevos, hasta 8 MiB de
JSON) y se pierden al reiniciarlo. La configuración va en `stack.json`, sección `dumps`.

## Seguridad

- Solo escucha en `127.0.0.1`; cada carga hasta 16 MiB.
- Nada se deserializa como objeto ni se ejecuta.

## Enlaces

- `butakestack://tool/dumps` (y el alias `butakestack://service/dumps`): abre la herramienta.

## Límites conocidos

- Solo el formato de VarDumper (PHP).
- Pruebas en la app: `ReceiverToolsTests.swift` (decodificación, búsqueda, pausa, opciones y
  `plugin_disabled`).
