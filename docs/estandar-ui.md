# Estándar de interfaz

Norma de diseño y de código de la app de Mac. Vale para todo código nuevo o modificado.
`scripts/lint-ui.sh` comprueba las prácticas de interfaz que se pueden automatizar contra los topes de
`scripts/lint-ui.baseline`, que solo bajan; hoy todos están en cero salvo `exemptions`:

| Contador | Qué cuenta |
|---|---|
| `fixed-font` | `.ui(size:)` o `.system(size:)` fuera de `Shared/Typography.swift` |
| `on-tap-gesture` | `onTapGesture` |
| `uppercased` | `.uppercased()` |
| `text-literal` | `Text("…")` con letras escritas a mano |
| `symbol-literal` | `systemName:`/`systemImage:` con un literal en vez de `Symbols` |
| `symbol-concept` | un valor de `Symbols` escrito a mano donde se elige un símbolo |
| `tinted-icon` | íconos teñidos del acento a mano |
| `third-party` | nombres de aplicaciones o gestores de terceros |
| `old-product-name` | el nombre anterior del producto en textos, código o scripts de empaquetado |
| `deprecated-containers` | `CardBlock`, `CardSection`, `RowGroup`, `GroupedRow`, `SettingRow`, `HeaderCard`, `PageHeader` |
| `fixed-size-vertical` | `fixedSize(horizontal: false, vertical: true)` |
| `dialog-without-cancel` | `.confirmationDialog`/`.alert` sin `Button(L("common.cancel"), role: .cancel)` (un aviso de un solo botón pasa si ese botón es el `role: .cancel`) |
| `plain-action-button` | `buttonStyle(.plain)` |
| `toolbar-item-without-label` | control de un `ToolbarItem` cuya etiqueta es un `Text` o una `Image` sueltos en vez de `Label` |
| `file-too-long` | archivos Swift de `native/Sources` de más de 500 líneas |
| `strings-order` | claves de `Localizable.strings` fuera del orden por área de `scripts/order-strings.py` (un prefijo nuevo se agrega a su tabla `AREAS`; `--write` reordena) |
| `exemptions` | líneas con `// lint-ui: <motivo>` |

Los contadores de bloque (diálogos y barra) los calcula `scripts/lint-ui-blocks.py`;
`LINT_UI_VERBOSE=1` muestra cada hallazgo.

**Exenciones.** Un caso legítimo lleva `// lint-ui: <motivo>` en su misma línea: ningún contador lo
cuenta, pero el script lo lista con archivo, línea y motivo, y tiene su propio contador con tope. Se usa lo
mínimo: los datos en mayúsculas pasan por `String.dataCapitals` (una sola exención) y los dibujos a
escala fija (diagrama de la base, vista previa de la terminal) toman su tamaño de `Font.drawing` en
`Shared/Typography.swift`, sin exención.

**`fixedSize` vertical.** Un texto o una vista con `fixedSize(horizontal: false, vertical: true)` fuera
de un `ScrollView`, `Form` o `List` pide su altura ideal al ancho mínimo: la ventana calcula un mínimo
más alto que ella, el split view se centra y todas las columnas (barra lateral incluida) quedan bajo la
barra de título. El texto envuelve por sí solo; si necesita el ancho de la fila se le da con
`.frame(maxWidth: .infinity, alignment: .leading)`. Solo un popover que toma la altura de su
formulario puede usarlo, como exención. El gancho `QA layout:` de `QA/QALayout.swift` marca
`LAYOUT FAIL` cuando una columna empieza bajo la barra de título, y `capturar.py` hace fallar la captura.

## Estructura de la app

Carpetas de `native/Sources/ButakeStack/` y qué hay en cada una:
[mapa-del-repositorio.md](mapa-del-repositorio.md#app-nativesourcesbutakestack). Una carpeta por
función; cada herramienta, en la suya.

## Arquitectura de información

### Barra lateral

```
Inicio
Proyectos            carpetas y proyectos de varias partes → proyectos (se pliega; plegada
                     muestra cuántos tiene)
Herramientas         solo las activas, en este orden: Git · Terminal · Cliente de bases de datos ·
                     Bóveda · Correo · Dumps · Registros (base, siempre)
Nube                 solo las cuentas activas: AWS · Google Cloud (sin ninguna, no aparece)
Componentes          Servicios · Lenguajes · Utilidades
```

**Proyectos sigue las carpetas del disco.** La carpeta de proyectos (`~/Stack/Projects` o la elegida en
Ajustes › Avanzado) es el árbol: cada subcarpeta es una carpeta de la barra lateral, anidada a cualquier
profundidad (sangría de un nivel por carpeta; cerrar una carpeta oculta lo que tiene dentro). Un proyecto de
varias partes es una carpeta del disco marcada como tal (clic derecho › Convertir en proyecto, o «Convertir»
en la sugerencia que aparece cuando una carpeta tiene dos o más repositorios con el mismo prefijo).

- Estados, siempre dichos con palabras: **No encontrado** (proyecto sin carpeta; clic derecho › Ubicar…, Quitar de
  Stack) y **Nuevo** (repositorio del disco que no es proyecto; botón Agregar). Nada se agrega ni se quita solo.
- Lo que se mueve en Finder se sigue solo; Stack avisa en una línea (««X» se movió a …»).
- Arrastrar un proyecto o una carpeta sobre otra carpeta (o sobre el título Proyectos, para sacarla) mueve la
  carpeta en el disco, siempre tras una confirmación que dice de dónde a dónde, y se deshace con ⌘Z.
- Clic derecho en una carpeta: Nueva carpeta aquí…, Mostrar en Finder, Cambiar nombre… (renombra en el disco) y
  Eliminar carpeta (solo vacías).

Herramientas, Nube y Componentes no se pliegan. Cada fila de Componentes abre su página con sus
categorías en la columna de contenido y la categoría en el detalle; la fila recuerda la última
categoría vista:

```
Servicios            Bases de datos · Caché y colas · Tiempo real · Búsqueda · Almacenamiento
Lenguajes            PHP · Node.js · Python · Java y Kotlin · Rust · Swift
Utilidades           Asistentes de IA · Líneas de comandos de nube · Git y GitHub en la terminal
```

Una ruta de categoría (`service`, `language`, `utilities`) selecciona su fila de Componentes y su
categoría. La búsqueda de la barra muestra las categorías que encuentra por su nombre o por lo que
contienen («Redis» → Caché y colas).

Sin logo ni nombre de la app, sin número de versión, sin buscador propio (se usa `.searchable`)
y sin «+» en el encabezado de sección. Un solo «+» en la barra de herramientas con tres
opciones: «Nuevo proyecto…», «Agregar proyecto existente…» e «Importar carpeta…».

### Ajustes (⌘,)

Las preferencias viven solo en Ajustes; la ventana no tiene una página «General».

| Pestaña | Contenido |
|---|---|
| General | Iniciar con la sesión, actualizaciones, tamaño de texto, versión |
| Apariencia | Tema |
| Red | Dominios `.test`, certificado local, servidor web y sus puertos, carpetas vigiladas |
| Herramientas | Catálogo con interruptores y datos de cada una |
| Cuentas | Cuentas de GitHub y Bitbucket (solo con la herramienta Git encendida) |
| Claves SSH | Las claves de Stack |
| Avanzado | Carpeta de proyectos (`~/Stack/Projects`), carpeta de datos y su traslado, exportar y restaurar configuración, enlaces de terminal |

### Páginas

- **Inicio:** cabecera de estado (solo si hay algo que hacer), proyectos por carpeta, servicios en uso.
  Cada carpeta (y «Sin carpeta») se pliega con su encabezado; el estado es uno con la barra lateral.
- **Proyecto:** Resumen · Entornos · Procesos (si hay) · Registros. La edición va en «Ajustes del
  proyecto…» (hoja). Sin pestaña «Configuración». El título aparece solo en la barra.
- **Servicio:** una fila por servicio con estado, versión, Iniciar/Detener y menú «⋯».
- **Lenguaje:** Versiones (la global marcada) · Instalar versión… · Opciones · Proyectos que lo
  usan. Las versiones de un lenguaje se gestionan solo aquí; la versión de un proyecto se elige
  en sus ajustes.
- **Utilidades:** una página por tipo (Asistentes de IA, Líneas de comandos de nube, Git y GitHub
  en la terminal), como Servicios por
  categoría, con su título en la barra: `Form(.grouped)` con una fila por utilidad: ficha, nombre,
  qué es, versión o «Sin instalar», «Instalar…»/«Actualizar a X» y menú «⋯». Las filas de
  utilidades en otros sitios (asistente, AWS) llevan a la página de su tipo.
- **Herramientas:** cada una con tres columnas reales (lista, contenido, detalle) y sus acciones
  en la barra de herramientas.

El estado del supervisor se dice una vez por pantalla; su fuente única es la barra inferior.

### Menús

Archivo (⌘N nuevo proyecto, ⌥⌘N agregar existente, ⌘W), Edición (⌘F buscar), Visualización
(barra lateral, tamaño de texto, plegar y desplegar todas las carpetas), Ir (⌘1…⌘9 por sección, ⇧⌘O abrir rápidamente, ⌘R recargar),
Proyecto (Iniciar/Detener, Abrir en el navegador, Mostrar en Finder, ⌘⌫ Quitar), Ventana y
Ayuda (Asistente de configuración…, documentación).

La app se comporta como una app normal mientras su ventana está abierta (Dock, ⌘Tab y barra de
menús) y vuelve a ser solo de barra de menús al cerrarla.

## Glosario

| Se dice | No se dice | Notas |
|---|---|---|
| Proyecto | Sitio | Claves `route.sites`, `home.noSites`, `site.delete`… |
| Servicio | Motor | MySQL, Redis, etc. |
| Herramienta | Complemento, plugin, módulo | Parte opcional de la app |
| Utilidad | Herramienta de desarrollo | `rustup`, `gh` y similares de línea de comandos |
| Entorno | — | Solo el conjunto `.env` de un proyecto |
| Versiones | «Entorno» del proyecto | `site.environment` |
| Configuración | «Mi entorno» | Lo que se exporta y restaura |
| Iniciar con la sesión | Agente de sesión, «Servir los sitios .test» | Un solo nombre |
| Iniciar / Detener | Encender / Apagar | Procesos y servicios |
| Activar / Desactivar | Instalar / Desinstalar | Herramientas que no descargan nada |
| Instalar / Quitar | Descargar / Borrar | Versiones y servicios |
| Eliminar | Borrar, Olvidar | Cuando se pierden datos |
| Quitar | — | Cuando solo sale de la lista |
| Tiempo real | Broadcasting | Servicios de WebSocket |
| Stack, servicio de fondo de Stack | Supervisor, motor, daemon | Lo que corre detrás de la app |
| Página web | Sitio web | Lo que un proyecto sirve en .test |

Mayúscula solo en la primera palabra. Los puntos suspensivos indican que la acción pide más
datos. Sin textos explicativos de más de una línea: lo que sobra va a `.help`. El código puede
seguir diciendo `engine` o `site` en identificadores internos; el glosario rige el texto visible.

## Prácticas obligatorias

### Interfaz

1. Estructura de ventana con `NavigationSplitView` (2 o 3 columnas), `HSplitView` o
   `.inspector`. Nunca `HStack` con anchos fijos para maestro-detalle.
   La ventana tiene siempre tres columnas del sistema (`App/RootView`, `App/ContentColumn.swift`):
   barra lateral, contenido y detalle, como Mail y Xcode. La de contenido se pliega en las páginas
   que no traen lista (siguen viéndose en dos columnas) y se abre en las que sí, sin reconstruir la
   barra lateral: se conservan su selección, desplazamiento, búsqueda y secciones. Cada columna
   tiene un solo divisor de arriba abajo, la barra de título comparte el fondo de su columna y el
   sistema recuerda el ancho de la de contenido con la ventana. Una página con lista y detalle
   (Git, Terminal, Cliente de bases de datos, Bóveda, Correo, Dumps, Registros, AWS, Google Cloud) adopta el patrón en dos líneas, sin `HSplitView` propio:

   ```swift
   // App/ContentColumn.swift
   case .tool("vault"): true                          // Route.hasContentColumn
   case .tool("vault"): VaultItemList(store: store)   // ContentColumn.body: la lista
   ```

   La vista de la página queda solo como detalle; lista y detalle comparten el estado por el
   modelo (`client.selection`), no por la jerarquía de vistas. La lista usa `List(selection:)`
   con `.listStyle(.sidebar)` (el fondo de la columna lo pone `ContentColumn`, también con tema
   propio) y su pie, si lo tiene, mide 29 pt con `Divider()` arriba, como la barra de estado. Las
   acciones van en la barra de herramientas del detalle, nunca en `.principal` (se centra en la
   ventana y cruza el divisor); el título de la ventana es corto porque se lee sobre la columna
   de contenido, y la ruta de lo elegido va en el propio detalle.
2. Secciones con filas: `Form { Section { LabeledContent } }.formStyle(.grouped)`.
3. Sin fondo pintado en el contenido, salvo con tema personalizado.
4. Cada página declara sus acciones en `.toolbar` (`primaryAction`, `secondaryAction`).
5. Búsqueda con `.searchable`.
6. Toda acción principal tiene ítem de menú y atajo estándar; las que actúan sobre la
   selección usan `@FocusedValue`.
7. Fuentes semánticas (`uiBody`, `uiHeadline`, `uiCaption`…). Prohibido `.ui(size:)` y
   `.system(size:)` en vistas.
8. Colores semánticos. El acento es el del sistema (Ajustes del Sistema › Aspecto): con el tema
   por defecto no se fuerza `tint` (`Brand.accent` es `Color.accentColor`); solo un tema que trae
   su propio acento lo aplica (`themedTint()`). El verde de marca solo para la marca y el estado
   correcto o en ejecución.
9. Todo lo pulsable es `Button` o un control. Prohibido `onTapGesture` para acciones.
10. Botón de solo ícono: `Label(...).labelStyle(.iconOnly)` con `.help` e identificador.
11. Un SF Symbol por concepto, tomado de `Symbols`. Sin alternar relleno y contorno por estado.
    Íconos de fila en ficha de color sólido con símbolo blanco (`IconTile`, o `TechLogo` con el
    logo del producto), como en Ajustes del Sistema: un color por concepto (`TileColor`), el
    mismo en toda la app; sin fichas teñidas del acento ni del verde de marca. El color de estado
    (correcto, aviso, error) solo cuando la ficha dice un estado.
12. Estados vacíos con `ContentUnavailableView`; en búsquedas, `.search(text:)`.
13. Confirmaciones con `.confirmationDialog` o `.alert` y `role: .destructive`. La acción
    destructiva nunca es la predeterminada.
14. Hojas: Cancelar (`.cancelAction`) a la izquierda y la acción (`.defaultAction`) a la
    derecha; tamaño mínimo e ideal, nunca fijo.
15. Columnas con `Table`; listas seleccionables con `List(selection:)`.
16. Encabezados de sección con mayúscula inicial, sin `.uppercased()` ni ícono decorativo.
17. Animaciones que respetan `accessibilityReduceMotion`; sin `scaleEffect` al pasar el ratón.
18. Ningún control invisible a la espera del ratón.
19. Rutas largas con `truncationMode(.middle)` y el valor completo en `.help`.
20. Navegación y pestaña activa persistidas con `@SceneStorage`.
21. Sin `.id(tema)` para forzar la recreación de vistas.
22. Todo se lee bien con el texto a 1,5× y en modo oscuro.
23. Lo que se puede revertir se registra con `store.undoable(nombre, undo:, redo:)`
    (`App/StackStore+Undo.swift`) cuando la acción salió bien, sobre el `UndoManager` de la ventana
    (⌘Z, ⇧⌘Z). `nombre` es lo que dice Edición («Iniciar Tienda»), con clave `menu.undo.*`.
    `undo` y `redo` repiten acciones del store: no registran de nuevo mientras corren. Se pide
    confirmación solo para lo irreversible (borrar una base, quitar un proyecto con sus secretos).
24. Un error se dice donde se pidió la acción: `store.run(…, from: .panel)` o `report(_, from:)`
    lo muestran en el panel de la barra de menús (`panelFailure`, nunca abre la ventana) o en la
    alerta de la ventana. Lleva título con el contexto (`failureTitle`), la causa si el motor la
    da, «Reintentar» (salvo `canRetry: false` si repetir deja restos) y «Abrir Registros» cuando
    la causa no se conoce.
25. Atrás y Adelante (⌘[, ⌘], botones de la barra y deslizar con dos dedos) siguen `store.history`
    (`App/RouteHistory.swift`): una página que se abre desde un enlace o la barra lateral entra sola.

### Contenido

26. Todo texto visible pasa por `L()` y usa solo términos del glosario.
27. Un dato o estado aparece una vez por pantalla. Un título no se repite en el contenido.
28. Una función tiene una sola entrada principal; las demás son atajos que llevan a ella.
29. Nada decorativo que no se pueda accionar: sin listas de «incluido», sin versiones «1.0.0».
30. Ningún nombre de aplicaciones o gestores de terceros que Stack reemplaza o evita.

### Código

31. Un archivo por responsabilidad, con un tope orientativo de 400 líneas. Carpeta por función.
32. Sufijos: `*Page` (destino de la barra lateral), `*Sheet` (hoja), `*Panel` (zona de una
    página), `*Row`, `*Section`. Lo compartido vive en `Shared/`.
33. Antes de crear un helper, buscar uno en `Shared/` (Swift) o `core/` (Rust).
34. Código de QA solo tras `#if DEBUG` y en `QA/`.
35. Identificadores de accesibilidad `<área>.<elemento>[.<id>]`, únicos, en todo control.
36. Sin código muerto, comentado ni alias «por si acaso». Lo que no tiene llamador se borra.
37. Motor: procesos con ejecutable y argumentos separados; validación, escritura privada,
    descarga verificada y extracción solo desde `core/`.
