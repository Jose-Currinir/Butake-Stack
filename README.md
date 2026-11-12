# Butake Stack

Entorno de desarrollo local nativo para Mac, en la barra de menús. Sirve tus sitios en `.test`
con HTTPS, HTTP/2 y HTTP/3, y corre directo en el Mac los runtimes y motores que necesitan: PHP,
Node, MySQL, PostgreSQL, MongoDB, Redis, Valkey, Meilisearch, Typesense y RustFS. Sin Homebrew,
sin Docker y sin tocar `/etc`.

- App SwiftUI/AppKit sin WebView, con temas (Butake, Drácula o personalizado).
- Motor y supervisor en Rust: un daemon mantiene arriba sitios y motores aunque cierres la app.
- Nada se descarga sin que lo elijas: cada herramienta sale de su fuente oficial, con su versión,
  su ciclo de vida (LTS, activa, mantenimiento) y su verificación (SHA-256, firma o compilación).
- macOS entrega los puertos 53, 80 y 443 al agente de sesión: sin contraseña ni cambios del sistema.
- Proyectos Laravel nuevos con el instalador oficial (starter kits, Pest, base de datos, Git),
  usando el PHP, Composer y Node del propio stack.
- Integrado con [Butake Git](https://github.com/Jose-Currinir/Butake-Git): rama y cambios por sitio,
  worktrees servidos como `<rama>.<sitio>.test` y apertura cruzada entre las dos apps.

Requiere macOS 15 o posterior en un Mac con Apple Silicon. Página:
[jose-currinir.github.io/Butake-Stack](https://jose-currinir.github.io/Butake-Stack/).

## Instalar

1. Descarga `Butake-Stack.dmg` de la [última versión](https://github.com/Jose-Currinir/Butake-Stack/releases/latest).
   Está firmado con el Developer ID de Butake SpA y notarizado por Apple; su suma SHA-256 está
   publicada junto al instalador.
2. Arrastra **Butake Stack** a Aplicaciones y ábrela: aparece en la barra de menús.
3. La primera vez se abre **Preparar Butake Stack** con lo que falta en tu Mac (PHP, Caddy, el
   agente de sesión; Node y las herramientas de Apple recomendados). Eliges cada versión y
   confirmas antes de que se descargue.

## Actualizar

La app busca versiones nuevas en GitHub al iniciar y cada 6 horas (o desde **Butake Stack ›
Buscar actualizaciones…**). Antes de reemplazarse comprueba la suma SHA-256 publicada y la firma
Developer ID de Butake SpA notarizada por Apple, y reinicia el agente de sesión sobre la copia nueva.

## Compilar

```bash
./scripts/test-native.sh      # pruebas del motor y de la app
./scripts/install-native.sh   # compila, instala en /Applications y abre
./scripts/package-dmg.sh      # DMG firmado y notarizado (requiere Developer ID)
```

## Documentación

- [Arquitectura](docs/architecture.md)
- [PHP propio](docs/php-runtimes.md)
- [Alcance](docs/alcance.md)
- [Herramientas relacionadas](docs/analisis-relacionados.md)
