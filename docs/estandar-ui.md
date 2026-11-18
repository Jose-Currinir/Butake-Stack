# Estándar de interfaz

Norma de diseño y de código de la app de Mac. Vale para todo código nuevo o modificado.
`scripts/lint-ui.sh` comprueba las prácticas de interfaz que se pueden automatizar contra los topes de
`scripts/lint-ui.baseline`, que solo bajan; hoy todos están en cero salvo `exemptions` y los tres de deuda
conocida que siguen (`system-font-style`, `icon-only-without-help`, `sheet-taller-than-window`):

| Contador | Qué cuenta |
|---|---|
| `fixed-font` | `.ui(size:)` o `.system(size:)` fuera de `Shared/Typography.swift` |
| `system-font-style` | `.font(.caption)`, `.callout`, `.body`… (estilos del sistema que no siguen el tamaño de texto de Stack; va `.uiCaption`, `.uiSubheadline`…). Tope por archivo (`system-font-style:<archivo>=n` en la línea base): arreglar uno no paga uno nuevo en otro |
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
| `icon-only-without-help` | `.labelStyle(.iconOnly)` cuyo control no lleva `.help` ni `accessibilityLabel` (cadena de modificadores del `Label` y de quien lo contiene) |
| `sheet-taller-than-window` | `.frame(… height:/minHeight: N)` con N mayor que 600, el alto de la ventana mínima: la hoja no cabe y pierde sus botones |
| `file-too-long` | archivos Swift de `native/Sources` de más de 500 líneas |
| `strings-order` | claves de `Localizable.strings` fuera del orden por área de `scripts/order-strings.py` (un prefijo nuevo se agrega a su tabla `AREAS`; `--write` reordena) |
| `exemptions` | líneas con `// lint-ui: <motivo>` |

Los contadores de bloque (diálogos, barra y botones de solo ícono) los calcula `scripts/lint-ui-blocks.py`;
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
| General | Iniciar con la sesión, avisos del sistema, actualizaciones, tamaño de texto, versión |
| Apariencia | Tema |
| Red | Dominios `.test`, certificado local, servidor web y sus puertos, carpetas vigiladas |
| Herramientas | Catálogo con interruptores y datos de cada una |
| Cuentas | Cuentas de GitHub y Bitbucket (solo con la herramienta Git encendida) |
| Claves SSH | Las claves de Stack |
| Avanzado | Carpeta de proyectos (`~/Stack/Projects`), carpeta de datos y su traslado, exportar y restaurar configuración, enlaces de terminal |

### Páginas

- **Inicio:** cabecera de estado (solo si hay algo que hacer); una línea de resumen grande («5 de 5 en
  marcha», y en gris servicios y avisos); «Necesita atención» solo si hay algo; los proyectos en una
  sola lista con columnas (Proyecto con tipo y versión, Dirección, Rama, Estado y una acción
  Iniciar/Detener), agrupada por carpeta; y los servicios en uso como fichas compactas. Cada carpeta
  (y «Sin carpeta») se pliega con su encabezado. Doble clic o Retorno abre el proyecto; el clic derecho
  trae el menú del proyecto. Con poco ancho se oculta primero Rama y luego Dirección (pasan al texto
  gris del nombre), nunca se corta una columna. Sin anillo ni interruptor: el estado es el punto con
  sus palabras. El estado es uno con la barra lateral.
- **Patrón de las páginas de un elemento** (un proyecto, un proyecto de varias partes, un tipo de servicio, un lenguaje, un tipo de utilidad): `Shared/DetailHeader.swift`.
  `DetailHeader` lleva el logo grande (`DetailHeaderLogo.size`), el nombre en grande, una línea debajo
  (tipo, versión, dirección) y a la derecha las acciones de la página con texto, la principal al final
  (`.borderedProminent`); con la ventana angosta las acciones pasan debajo del nombre, nunca se cortan.
  `DetailTabs` pone las pestañas bajo la cabecera (segmentado, o menú si no caben) con un solo filo. La
  barra de herramientas de la ventana queda solo con el «+».
- **Proyecto:** cabecera con el logo, el nombre, «Laravel · PHP 8.4 · https://tienda.test» (la dirección abre
  el navegador) y, a la derecha, el estado en palabras con su punto, Abrir, Código, Terminal, un menú «⋯»
  (Ajustes del proyecto…, Copiar dirección) y Iniciar/Detener. Un proyecto sin servidor no lleva estado,
  Abrir ni Iniciar/Detener. Pestañas: Resumen · Entornos · Procesos (si hay) · Registros (⌃⌥1…4). La edición
  va en «Ajustes del proyecto…» (hoja); sin pestaña «Configuración». Resumen no repite lo que dice la
  cabecera (estado, dirección) y usa dos columnas de secciones desde 1100 pt de ancho de página, una
  columna debajo. Procesos: una acción visible por fila (el interruptor) y el estado en palabras;
  Registros y Reiniciar van en el menú «⋯» de la fila y en su clic derecho.
- **Proyecto de varias partes:** la misma cabecera (símbolo, nombre, «N partes», Detener todo e Iniciar todo).
- **Servicio (tipo):** cabecera `DetailHeader` con la ficha del tipo, su nombre («Bases de datos») y
  debajo «2 en marcha de 3». Sin acciones en la cabecera: Instalar va en cada fila. Debajo, una fila
  por servicio con estado, versión, Iniciar/Detener y menú «⋯». La barra de herramientas queda con el «+»
  de la ventana.
- **Lenguaje:** cabecera `DetailHeader` con el logo grande, el nombre («PHP»), debajo «Global 8.4.27 · 2
  versiones instaladas» (sin versiones: «Sin instalar») y, a la derecha, el botón principal «Instalar
  versión…» (donde un instalador previo lo exige, como Rust y Swift, su fila ocupa su lugar). Debajo:
  Versiones (la global marcada) · Opciones · Proyectos que lo usan, sin repetir lo que dice la cabecera.
  Desde 1100 pt de ancho de la página, Versiones va a la izquierda y el resto a la derecha. Las
  versiones de un lenguaje se gestionan solo aquí; la versión de un proyecto se elige en sus ajustes.
- **Utilidades:** una página por tipo (Asistentes de IA, Líneas de comandos de nube, Git y GitHub
  en la terminal). Cabecera `DetailHeader` con la ficha del tipo, su nombre y «N instaladas de M»; su
  acción, «Buscar versiones nuevas», va en la cabecera con su texto. Debajo, `Form(.grouped)` con una
  fila por utilidad: ficha, nombre, qué es, versión o «Sin instalar», «Instalar…»/«Actualizar a X» y menú
  «⋯». Las filas de utilidades en otros sitios (asistente, AWS) llevan a la página de su tipo.
- **Páginas con cabecera (Proyecto, Servicio, Lenguaje, Utilidades):** las acciones de la página van en
  la cabecera con su texto, la principal al final; la barra de herramientas queda con el «+» de la ventana.
- **Herramientas:** cada una con tres columnas reales (lista, contenido, detalle) y sus acciones
  en la barra de herramientas.

El estado del supervisor se dice una vez por pantalla; su fuente única es la barra inferior.

### Menús

Archivo (⌘N nuevo proyecto, ⌥⌘N agregar existente, ⌘W), Edición (⌘F buscar), Visualización
(barra lateral, tamaño de texto, plegar y desplegar todas las carpetas), Ir (⌘1…⌘9 por sección, ⇧⌘O abrir rápidamente, ⌘R recargar),
Proyecto (Iniciar/Detener, Abrir en el navegador, Mostrar en Finder, ⌘⌫ Quitar), Ventana y
Ayuda (Asistente de configuración…, documentación).

La app se comporta como una app normal mientras su ventana está abierta (Dock, ⌘Tab y barra de
menús) y vuelve a ser solo de barra de menús al cerrarla. Abrir Stack otra vez estando en marcha y
sin ventana (Finder, Spotlight) muestra la ventana principal; al iniciar la sesión no se abre ninguna.

El icono de la barra de menús es una imagen plantilla; lleva un punto (una forma, no un color)
mientras el estado no es «Todo en marcha», y su descripción accesible dice el estado. La barra
inferior dice «Reconectando…» durante 5 s desde que el servicio deja de contestar y solo después
«Detenido»; una lectura que cruzó la suspensión del Mac empieza esa espera otra vez.

Avisos del sistema (Ajustes › General › Avisos): apagados al instalar; macOS pide el permiso solo al
encenderlos. Avisan una vez por episodio, y solo con la ventana en segundo plano, de una actualización
lista, un proceso de un proyecto que se detuvo y una instalación que terminó; tocar el aviso abre la
página del asunto.

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
`GlossaryTests` lee `Localizable.strings` y falla con las palabras de la columna «No se dice»; un caso
legítimo (el sitio web de un tercero, el «módulo» de Gradle, «se borra el portapapeles») va en su lista
de excepciones con el motivo.

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
    La barra lateral usa símbolos monocromos del sistema (`Label` con el símbolo de `Symbols`; macOS
    los tiñe y los pone blancos al seleccionar) y, en las filas de proyecto, el logo pequeño del
    proyecto (`TechLogo`) con su estado como punto (`SidebarStateDot`, sobre `StatusDot`: verde en
    marcha, contorno gris detenido, ámbar o rojo si falla; con «Diferenciar sin color», un símbolo de
    forma propia). Nube (AWS, Google Cloud) usa el símbolo de nube, no su logo. Las fichas de color
    sólido con símbolo blanco (`IconTile`, `TechLogo`) quedan para Ajustes, las listas de cada
    herramienta y las páginas de Componentes: un color por concepto (`TileColor`), el mismo en toda
    la app; sin fichas teñidas del acento ni del verde de marca. El color de estado (correcto,
    aviso, error) solo cuando la ficha dice un estado.
12. Estados vacíos con `ContentUnavailableView`; en búsquedas, `.search(text:)`.
13. Confirmaciones con `.confirmationDialog` o `.alert` y `role: .destructive`. La acción
    destructiva nunca es la predeterminada.
14. Hojas: Cancelar (`.cancelAction`) a la izquierda y la acción (`.defaultAction`) a la
    derecha; tamaño mínimo e ideal, nunca fijo.
15. Columnas con `Table`; listas seleccionables con `List(selection:)`.
16. Encabezados de sección con mayúscula inicial, sin `.uppercased()` ni ícono decorativo.
17. Animaciones que respetan `accessibilityReduceMotion`; sin `scaleEffect` al pasar el ratón. Todo
    movimiento pasa por `Shared/Motion.swift` (`Motion.run`, `.animated`, `.transitioned`); `lint-ui.sh`
    cuenta `raw-animation` (tope 0). Contraste: un color de estado escrito como texto usa
    `Brand.successText/warningText/dangerText/infoText` (4,5:1, probado en `BrandContrastTests`); el
    color pleno queda para iconos y bordes. Con Aumentar contraste, tintes y bordes salen de
    `tintedFill`/`separatorEdge` (`Shared/Styles.swift`). Un punto de estado es un `StatusDot`
    (forma con «Diferenciar sin color»). Radios de `Radius` (6, 8, 12, 16).
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
    El aviso «Hecho: … · Deshacer» dura 8 s más 0,1 s por carácter pasado de 30 (tope 20 s) y
    espera mientras el puntero o el foco estén sobre él. Todo lo que se dice a VoiceOver sale por
    `store.announce` (avisos de `notify`, el aviso de deshacer y lo deshecho o rehecho): no se
    publica un anuncio aparte. También son deshacibles mover un proyecto de carpeta, quitar una
    carpeta (solo el agrupamiento) y mover un host SSH de grupo.
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
38. Un error pesa según lo que cuesta (`FailureImpact`). **Bloquea**: la acción que el usuario pidió no se
    hizo y debe decidir: alerta con título de contexto, «Reintentar», «Abrir Registros» y «Copiar detalles»
    (es el valor por omisión). **Parcial**: la página funciona y falló una lectura o una parte: una línea
    `Notice(.warning)` en esa página con «Reintentar» (`PartialFailureNotice`, `store.readDone`), nunca un
    modal, con los datos anteriores debajo. Una lectura que falla no se escribe `try? … ?? []`: un vacío
    es «no hay», un fallo es «no se pudo leer». Las lecturas que se repiten solas (sondeos) avisan solo
    tras dos fallos seguidos; las de fondo de Inicio, estado y Git siguen en silencio hasta que tengan su
    página. «Informar de un problema…» (Ayuda) arma un texto local, sin secretos, y no envía nada.
