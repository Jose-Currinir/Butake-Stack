# Butake Stack

Entorno de desarrollo local para macOS, propio de Butake: reemplaza a DBngin y los
servicios sueltos de Homebrew. Producto canónico: SwiftUI/AppKit en `native/`, motor Rust en
`engine/` (CLI JSON + daemon supervisor). Sin WebView.

- Trabajar en `develop`. `main` es promoción/release; no push directo.
- Código y archivos nuevos en inglés; texto visible en español mediante `L` y
  `native/Sources/ButakeStack/Resources/es.lproj/Localizable.strings`.
- El usuario configura todo desde la UI: proyecto, carpeta, dominio local, lenguaje/versión y
  servicios. La configuración vive en `~/Library/Application Support/Butake Stack/`, nunca en
  el repo del proyecto.
- Sin interpolación de shell: cada proceso recibe ejecutable y argumentos separados. Validar
  rutas (canonicalizar), dominios (`[a-z0-9-]` + TLD permitido) y puertos.
- Secretos: no leer, copiar ni registrar valores del `.env` de los proyectos; sólo se lee qué
  claves existen y los puertos. Contraseñas de servicios propios en el Llavero.
- Acciones con privilegio (resolver `/etc/resolver/<tld>`, confiar la CA local) sólo con
  confirmación explícita y el diálogo de administrador de macOS; nunca guardar la clave.
- No detener aplicaciones de terceros (DBngin, servicios de Homebrew u otras) sin confirmación en la UI; mostrar quién
  ocupa cada puerto antes de tomarlo.
- Migraciones de datos (dump DBngin → MySQL propio) sólo leen el origen; nunca lo borran.
- QA contra proyectos y datos temporales; nunca mutar bases reales para probar.
- Operable por IA: todo control con `accessibilityIdentifier` estable.
- Validar `./scripts/test-native.sh`, `./scripts/build-native.sh`, `git diff --check`; verificar
  visualmente los cambios de UI.
- No publicar, crear remoto ni push salvo instrucción del usuario.

Fuentes: README.md, docs/architecture.md. Plan, reportes y bitácora locales: internal/ (no
versionada). Patrón de referencia: `../Butake-Git`.
