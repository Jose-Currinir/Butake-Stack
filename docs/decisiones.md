# Decisiones vigentes

Decisiones de producto y de arquitectura. Una línea por decisión, con su fecha y su motivo. Las más
nuevas, arriba. Las entradas no se reescriben: una decisión que cambia agrega una entrada nueva que dice
a cuál reemplaza, y la vieja queda marcada «reemplazada por la del <fecha>» (sin borrar su texto). Antes
de cambiar un texto, un lugar o una regla de la interfaz, se busca aquí si ya hay una decisión.

| Fecha | Decisión | Motivo |
|---|---|---|
| 2026-11-18 | Rediseño A: la barra lateral usa símbolos grises del sistema y, en cada proyecto, su logo chico y un punto de estado; las fichas de color quedan para Ajustes, las listas de cada herramienta y las páginas de Componentes | Doce colores en la barra competían con lo importante; el color queda para la identidad del proyecto y su estado |
| 2026-11-18 | Las páginas de un elemento (proyecto, proyecto de varias partes, tipo de servicio, lenguaje, tipo de utilidad) abren con `DetailHeader`: logo grande, nombre en grande, una línea debajo y sus acciones con texto; las pestañas van debajo y la ventana no repite el subtítulo | El nombre era lo más chico de la página y las acciones eran iconos sin texto en la barra |
| 2026-11-18 | Las herramientas de tres columnas (Git, Terminal, Bases de datos, Bóveda, Correo…) siguen con sus acciones en la barra de herramientas | Es el patrón de Mail y Xcode para lista y detalle; una cabecera grande quitaría lugar a la lista |
| 2026-11-18 | Inicio es una sola lista con columnas por carpeta (proyecto, dirección, rama, estado, Iniciar/Detener), con `List` y no `Table` | `Table` no pliega carpetas anidadas ni deja ocultar columnas cuando falta ancho |
| 2026-11-18 | Avisos de macOS para una actualización lista, un proceso que se detuvo y una instalación terminada: vienen apagados (Ajustes › General), uno por episodio y solo con Stack en segundo plano | Útiles con la ventana cerrada sin volverse ruido; el permiso de macOS se pide solo al encenderlos |
| 2026-11-18 | El icono de la barra de menús lleva un punto (forma, no color) mientras el estado no es «Todo en marcha» | Stack vive en la barra de menús: con la ventana cerrada es el único lugar donde se ve que algo falla |
| 2026-11-18 | Una acción pedida que no se hizo es una alerta; una lectura o una parte que falló es una línea en su página, con Reintentar | Un fallo menor no bloquea la ventana, y «no se pudo leer» no se confunde con una lista vacía |
| 2026-11-18 | «Informar de un problema…» arma un texto sin secretos que queda en el Mac: el usuario lo copia o lo guarda; Stack no envía nada | Diagnóstico sin abrir un canal de datos hacia afuera |
| 2026-11-18 | Los atajos viven en un solo registro (`Shared/Shortcuts.swift`), con una prueba de choques: Atrás de la Bóveda es Esc, Actualizar de Bases de datos ⌥⌘R, Atajos de teclado ⌘/ y Ocultar lista ⌥⌘L | ⌘[ y ⌘R hacían dos cosas a la vez |
| 2026-11-18 | La barra lateral muestra un número solo para lo que pide atención (Inicio, Proyectos plegado); Correo no lo lleva | El total de mensajes capturados nunca baja y no dice nada nuevo |
| 2026-11-18 | Las ediciones sin guardar de una tabla viven en el cliente de bases de datos: cambiar de página o cerrar la ventana las conserva; desconectar y salir de Stack preguntan | No se pierde trabajo sin aviso |
| 2026-11-18 | «Iniciar con la sesión» registra el servicio de fondo y también la app (`SMAppService.mainApp`), con un solo interruptor | El texto prometía que Stack se abría al iniciar sesión y solo arrancaba el servicio |
| 2026-11-18 | El texto de un estado se calcula hasta 4,5:1 de contraste en cada tema, y toda animación pasa por `Shared/Motion.swift`, que respeta «Reducir movimiento» | Legible en el tema claro y con los ajustes de accesibilidad de macOS |
| 2026-11-18 | Sin ventana aparte por página ni selección de varios proyectos a la vez, por ahora | Se revisa cuando haya un caso real que lo pida |
| 2026-11-18 | Git: Actualizar y Bajar podan las ramas borradas en el remoto; una rama combinada y borrada allí se elimina de este Mac con un botón, después de comprobar que sus commits están en el remoto | Un pull request combinado en la web dejaba la rama listada en Stack |
| 2026-11-16 | Skills: una carpeta plana por skill en la carpeta de datos de Stack; el grupo y las etiquetas viven solo en `index.json` y las IA reciben enlaces, nunca copias | Cambiar de grupo o renombrar un grupo no rompe ningún enlace; una sola copia real por skill (R23) |
| 2026-11-14 | Renombrar o mover un proyecto encendido lo detiene y lo vuelve a iniciar; no se rechaza | Sus procesos no pueden escribir registros mientras estos cambian de nombre, y rechazar obligaba a un paso manual |
| 2026-11-14 | El motor nunca lee el Llavero: al renombrar, la app copia, verifica y recién entonces borra los ítems de Entornos | Sin secretos huérfanos ni copias duplicadas (R22) |
| 2026-11-14 | Proyecto de varias partes = una carpeta marcada `"kind": "project"`; cada parte sigue siendo un proyecto | Un producto real se compone de varios repositorios, sin migrar ni romper `groups.json` |
| 2026-11-14 | En Git, ver, actualizar y bajar son conjuntos; confirmar y subir, siempre de un repositorio a la vez | Seguridad: un commit o una subida nunca alcanzan a más de lo que el usuario revisó |
| 2026-11-14 | La barra lateral: Inicio, Proyectos, Herramientas (lo que se usa), Nube (cuentas) y Componentes (lo que se instala) | «Utilidades» y «Herramientas» se confundían y la barra creció sin orden |
| 2026-11-14 | Git pasa a ser una herramienta de Stack, apagada por defecto | Un solo producto modular; el motor se trae casi literal con sus pruebas y la interfaz se rehace con las reglas de Stack. El retiro de la app Butake Git espera una decisión aparte |
| 2026-11-14 | Toda herramienta se compila dentro de la app firmada; «instalar» es activar | Descargar código aparte rompería la firma única y la revisión de seguridad |
| 2026-11-14 | Stack no abre la app Butake Git: `butakestack://git?path=` abre la herramienta | Una sola entrada principal por función. Tomada al cerrar Git en Stack; falta la confirmación del titular |
| 2026-11-14 | Fichas de GitHub y Bitbucket: un ítem del Llavero por cuenta, solo hacia la API del proveedor | Nunca al motor, a Git, a disco ni a la interfaz (R19) |
| 2026-11-14 | Google Cloud usa las cuentas que gcloud ya tiene, sin leer credenciales ni cambiar su configuración | Trabajar con las cuentas del usuario sin custodiar sus credenciales (R17) |
| 2026-11-14 | Dirección fija: un túnel con nombre por proyecto, por defecto `<id>-test.<zona>`; compartir vive en memoria | Ingreso con proveedores y enlaces absolutos necesitan una dirección estable; el certificado universal cubre un solo nivel (R16) |
| 2026-11-14 | Secretos de Entornos: un ítem del Llavero por proyecto y entorno, con los nombres en sus atributos | Un permiso por entorno y no por variable; abrir Entornos no lee valores |
| 2026-11-14 | La app se firma con una identidad estable y un requisito designado fijo, sin derechos | «Permitir siempre» del Llavero sobrevive a las actualizaciones |
| 2026-11-14 | La Bóveda importa un respaldo sin leer volcados ni cuarentenas, y un enlace solo propone la importación | Minimización: lo sensible que no se pidió no se lee (R20, R21) |
| 2026-11-13 | El producto se llama «Stack»; el código y los identificadores siguen diciendo «butake» | Nombre visible corto sin romper datos, Llavero ni enlaces existentes; la carpeta de datos se traslada solo a pedido |
| 2026-11-13 | El acento es el del Mac; el verde de marca solo para el logo y el estado correcto | La app se ve como el resto del sistema; el color de estado no se confunde con la selección |
| 2026-11-13 | Bóveda y Entornos son almacenes distintos y enlazados: Entornos para correr, Bóveda para firmar y publicar | Un solo lugar por propósito; un `.env` vive solo en Entornos (R13 para moverlo) |
| 2026-11-13 | Sin emuladores de servicios de nube: se administran sus líneas de comandos y perfiles | Peso, licencias y mantenimiento desproporcionados para lo que aporta |
| 2026-11-13 | Las claves SSH son de la base, no de una herramienta | Las usan la Terminal y los túneles del cliente de bases; apagar una no debe perderlas |
| 2026-11-13 | Una sola palabra para lo opcional: «Herramienta»; «Proyecto», no «Sitio»; «Servicio», no «Motor» | Un glosario sin sinónimos ([estandar-ui.md](estandar-ui.md#glosario)) |
| 2026-11-13 | Ajustes viven solo en ⌘,; el estado se dice una vez, en la barra inferior | Una función, una entrada principal |
| 2026-11-13 | Sin nombres de aplicaciones o gestores de terceros que Stack reemplaza, en la interfaz, el sitio y la documentación | Stack no se define por lo que reemplaza |
| 2026-11-12 | Los secretos de Entornos solo en el Llavero; el motor solo lee el `.env` que escribió Stack | Medida de seguridad del responsable (R1 a R12) |
| 2026-11-11 | Nada va fijo ni se descarga solo: cada pieza se elige de un catálogo de la fuente oficial, con su versión y su verificación | Todo personalizable y verificable |
| Desde el inicio | App SwiftUI/AppKit sin WebView; motor Rust con CLI JSON por stdin y daemon supervisor | Nativo en Mac; la app es solo la cara y cerrarla no baja los proyectos |
| Desde el inicio | Sin root: launchd abre 53, 80 y 443 para el agente de sesión; todo escucha en 127.0.0.1 | Nada expuesto a la red y una sola autorización de administrador (el resolver) |
| Desde el inicio | Sin shell: cada proceso con ejecutable y argumentos separados | Sin inyección de comandos |
| Desde el inicio | PHP propio, estático y por versión; el resto, binarios oficiales verificados por versión | Sin gestores de paquetes ni contenedores |
