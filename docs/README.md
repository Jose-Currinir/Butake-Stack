# Documentación de Stack

Un documento por tema. Las reglas para agentes están en [AGENTS.md](../AGENTS.md); la presentación,
en [README.md](../README.md).

## Cómo está hecho

- [architecture.md](architecture.md): daemon, CLI JSON, datos en disco, lenguajes, servicios, Caddy, DNS, seguridad y enlaces `butakestack://`.
- [mapa-del-repositorio.md](mapa-del-repositorio.md): árbol comentado del motor, la app, las pruebas y los scripts.
- [proyectos.md](proyectos.md): modelo de proyecto, carpetas y varias partes, renombrar y mover, entornos, marcadores, direcciones y Google Cloud.
- [decisiones.md](decisiones.md): decisiones de producto y arquitectura vigentes, con fecha y motivo.

## Herramientas

- [herramientas.md](herramientas.md): la base frente a las herramientas, el catálogo y la barra lateral.
- [herramientas/git.md](herramientas/git.md): cliente de Git, GitHub y Bitbucket.
- [herramientas/terminal.md](herramientas/terminal.md): consolas de este Mac, hosts SSH, SFTP y reenvíos.
- [herramientas/bases-de-datos.md](herramientas/bases-de-datos.md): cliente de MySQL, PostgreSQL, Redis, Valkey y SQLite.
- [herramientas/boveda.md](herramientas/boveda.md): lo que se usa para firmar y publicar, cifrado.
- [boveda-formato.md](boveda-formato.md): formato en disco de la Bóveda, `.butakevault`, respaldos y «Firma».
- [herramientas/correo.md](herramientas/correo.md): servidor SMTP de captura.
- [herramientas/dumps.md](herramientas/dumps.md): receptor de `dump()`.
- [herramientas/aws.md](herramientas/aws.md): perfiles de AWS CLI.
- [herramientas/google-cloud.md](herramientas/google-cloud.md): cuentas de gcloud y enlace por proyecto.
- [herramientas/registros.md](herramientas/registros.md): registros de los procesos (base).
- [como-agregar-una-herramienta.md](como-agregar-una-herramienta.md): pasos y archivos para una herramienta nueva.

## Trabajar en el repositorio

- [pruebas-y-qa.md](pruebas-y-qa.md): cadena de validación, qué cubre cada conjunto, una prueba sola, QA visual y dobles.
- [estandar-ui.md](estandar-ui.md): candado de interfaz, arquitectura de información, glosario y prácticas obligatorias.
- [operations.md](operations.md): primer inicio, registros y su filtro, copias, traslado de la carpeta de datos y firma.
- [php-runtimes.md](php-runtimes.md): fabricación y distribución del PHP propio.

## Otros

- [aws.md](aws.md): aviso de traslado a `herramientas/aws.md` (lo nombra el código).
- `presentacion/`: capturas que usa el sitio (`site/`), en claro y oscuro. Se regeneran con `python3 site/scripts/capturas.py` (ventana de QA y almacén de demostración temporal).
- [.compliance/RESUMEN.md](../.compliance/RESUMEN.md): cumplimiento de la Ley 21.719, con el índice de requisitos R1 a R22.
