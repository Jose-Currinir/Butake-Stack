# Stack

Stack, de Butake: entorno de desarrollo local nativo para Mac. Para quien desarrolla en un Mac con
Apple Silicon y quiere servir sus proyectos en dominios `.test` con HTTPS, y correr los lenguajes y
servicios que necesitan directo en el Mac, sin gestores de paquetes ni contenedores, desde una sola
app.

- App SwiftUI/AppKit sin WebView, en la barra de menús, con temas.
- Motor en Rust: un daemon mantiene arriba proyectos y servicios aunque cierres la app.
- Nada se descarga sin que lo elijas: cada pieza sale de su fuente oficial, con su versión, su ciclo
  de vida y su verificación (SHA-256, firma o compilación).

Requiere macOS 15 o posterior en un Mac con Apple Silicon. Página:
[jose-currinir.github.io/Butake-Stack](https://jose-currinir.github.io/Butake-Stack/).

## Qué hace

- **Proyectos**: carpeta, dominios `.test` con HTTPS, HTTP/2 y HTTP/3, versión de cada lenguaje y
  procesos supervisados. Laravel, PHP, estáticos, Node.js, proxy, Astro, EmDash, Next.js, KMP, Django,
  FastAPI y Rust; el asistente crea proyectos nuevos con el generador oficial de cada uno. Carpetas y
  **proyectos de varias partes** (por ejemplo, una web y su servidor, cada uno con su repositorio).
  Renombrar y cambiar de carpeta sin dejar nada huérfano.
- **Servicios**: MySQL, PostgreSQL, MongoDB, Redis, Valkey, Meilisearch, Typesense y RustFS, con
  varias versiones.
- **Lenguajes**: PHP (compilación propia), Node.js, Python, Java, Rust y Swift.
- **Utilidades**: asistentes de IA, líneas de comandos de nube, y Git y GitHub en la terminal,
  instalados desde la fuente de cada fabricante y verificados.
- **Entornos**: conjuntos `.env` por proyecto (Local, Pruebas, Producción…), con los secretos en el
  Llavero y marcadores que apuntan al puerto o a la dirección de otro proyecto.
- **Compartir**: una dirección temporal en internet o una **dirección fija** en un dominio propio.
- **Herramientas** que se activan en Ajustes › Herramientas, todas dentro de la app:
  Git, Terminal, Cliente de bases de datos, Bóveda, Correo, Dumps, AWS y Google Cloud, más Registros.

## Instalar

1. Descarga `Butake-Stack.dmg` de la [última versión](https://github.com/Jose-Currinir/Butake-Stack/releases/latest).
   Está firmado con el Developer ID de Butake SpA y notarizado por Apple; su suma SHA-256 está
   publicada junto al instalador.
2. Arrastra **Stack** a Aplicaciones y ábrela: aparece en la barra de menús.
3. La primera vez se abre el **asistente de configuración**: «¿Con qué trabajas?» y la base que falta
   (Caddy, iniciar con la sesión, los dominios `.test`, PHP y Node.js según tu trabajo). Eliges cada
   versión y confirmas antes de que se descargue. Se vuelve a abrir desde **Ayuda › Asistente de
   configuración…**.

La app busca versiones nuevas al iniciar y cada 6 horas (o desde **Stack › Buscar
actualizaciones…**) y antes de reemplazarse comprueba la suma publicada y la firma.

## Compilar y probar

En Apple Silicon, con Xcode (SDK de macOS 26 o posterior), Rust estable y Python 3:

```bash
./scripts/test-native.sh      # pruebas del motor y de la app, y el candado de interfaz
./scripts/build-native.sh     # compila y firma build/native.noindex/Stack.app
./scripts/package-dmg.sh      # DMG firmado y notarizado (requiere Developer ID)
```

Cadena completa y QA: [docs/pruebas-y-qa.md](docs/pruebas-y-qa.md). Reglas para agentes:
[AGENTS.md](AGENTS.md).

## Documentación

Índice completo en [docs/README.md](docs/README.md). Para empezar:

- [Arquitectura](docs/architecture.md) y [mapa del repositorio](docs/mapa-del-repositorio.md)
- [Proyectos](docs/proyectos.md)
- [Herramientas](docs/herramientas.md)
- [Pruebas y QA](docs/pruebas-y-qa.md)
- [Decisiones](docs/decisiones.md)
