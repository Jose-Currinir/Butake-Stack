# Decisiones vigentes

Decisiones de producto y de arquitectura que siguen en pie. Una línea por decisión, con su fecha y su
motivo. Las más nuevas, arriba. Una decisión que cambia se reemplaza aquí, no se agrega otra.

| Fecha | Decisión | Motivo |
|---|---|---|
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
