# Herramientas relacionadas

Lo marcado como «instalado» se verificó en este Mac el 2026-11-11; el resto describe el
producto en general, sin versiones ni precios.

## 1. Lo que ya tienes instalado

| Herramienta | Para qué la usas | Qué hace Butake Stack |
|---|---|---|
| **DBngin** (instalado) | MySQL 8.0.33 en el 3306 | **Lo reemplaza**: MySQL/Postgres/Redis supervisados, con datos migrados por dump (T-08) |
| **TablePlus** (instalado) | Cliente de bases | **Se integra, no se reemplaza**: botón «Abrir en TablePlus» con la conexión del proyecto (URL `mysql://` sin guardar la clave en disco). Un cliente SQL completo es otro producto |
| **Docker Desktop** (instalado) | Postgres de Butake-Gestion (`compose.local.yaml`) | **Lo vuelve opcional** para el día a día: Postgres nativo. Docker queda para probar imágenes de despliegue |
| **Postman** (instalado) | Probar APIs | Fuera de alcance. Butake Stack sólo aporta el dominio y el HTTPS estables para las colecciones |
| **Homebrew** `redis`, `dnsmasq`, `cloudflared` | Redis activo; dnsmasq/cloudflared sin uso | Redis pasa al stack. `cloudflared` se reutiliza para compartir sitios (ver Expose) |

## 2. Herramientas de escritorio para Laravel

| Herramienta | Qué hace | Qué tomar |
|---|---|---|
| **Expose** | Túnel público hacia un sitio `.test` | Usar **Cloudflare Tunnel** (`cloudflared` ya instalado, cuenta Butake existente): «Compartir» con URL temporal, y se apaga solo |
| **Tinkerwell** (no instalado) | Tinker con editor, autocompletado y conexión a servidores | Consola `tinker` integrada por proyecto con la versión de PHP correcta. Sin conexión a producción |
| **Ray** (no instalado) | Ventana de depuración para `ray()`/dumps | Lo cubre la ventana de dumps de la fase 3 (paquete puente) |
| **HELO** (no instalado) | Capturador de correo de escritorio | Lo cubre la bandeja de correo de la fase 2 |
| **Invoker** (no instalado) | Panel Laravel (logs, colas, modelos) sobre SSH | Ideas útiles para la vista de colas y modelos; sin SSH a servidores |

## 3. Paquetes de Laravel relacionados

| Paquete | En Gestión | Relación con Butake Stack |
|---|---|---|
| **Sail** | En `require-dev`, sin uso | Butake Stack es la alternativa nativa; Sail queda para quien prefiera Docker |
| **Pail** | En `require-dev` | Sigue sirviendo en terminal; la app muestra los mismos logs en el visor unificado |
| **Valet** | — | No se usa su ruteo por `server.php`; Caddy sirve directo |
| **Telescope / Debugbar** | No instalados | Hacen captura de requests dentro de la app; la fase 3 lo hace **fuera** de la app, sin tablas ni rutas extra en el proyecto |
| **Horizon** | No (colas con `queue:work` y supervisor) | La vista de colas de Butake Stack cubre lo local sin cambiar cómo corre producción |
| **Pulse** | No | Métricas de producción; fuera de alcance local |
| **Reverb** | Sí (8082) | Proceso supervisado del proyecto, en 127.0.0.1, opcional `wss://` por el dominio |

## 4. Alternativas en Mac

| Producto | Enfoque | Qué aprender | Qué evitar |
|---|---|---|---|
| **ServBay** | App nativa con muchos lenguajes (PHP, Node, Python, Go, Java…) y bases | Panel multi-lenguaje y servicios en un lugar: es lo más parecido a Butake Stack | Instalaciones enormes y todo encendido por defecto |
| **FlyEnv** (código abierto) | Gestor de muchos servicios y versiones | Catálogo amplio de módulos | UI web/Electron, mucho para configurar |
| **MAMP Pro / XAMPP** | Apache + MySQL clásicos | — | Stack viejo, poca aislación |
| **LocalWP** | WordPress local | Clonar/compartir sitios con un clic | Sólo WordPress |
| **OrbStack** | Docker y VMs livianas para Mac | Rapidez y bajo consumo; dominios `*.orb.local` automáticos | Sigue siendo contenedores |
| **DDEV / Lando** | Entornos por proyecto sobre Docker, configuración en el repo | **Manifiesto por proyecto versionado**: un compañero levanta todo con un comando | Dependen de Docker y son lentos en Mac |
| **Laragon** | Entorno PHP todo en uno, en Windows | Simplicidad «abrir y funciona» | Sólo Windows |

## 5. Qué agrega este análisis al plan

1. **Integraciones en vez de reemplazos**: TablePlus, el editor (Cursor/VS Code), la terminal y
   Butake Git abren con el contexto del proyecto (carpeta, conexión, rama).
2. **Compartir con Cloudflare Tunnel** en lugar de Expose (fase 2).
3. **Manifiesto `butake-stack.json` en el repo** al estilo DDEV/Lando, pero sin Docker (ya
   previsto; sube a fase 1 como opcional en T-06).
4. **Multi-lenguaje como ServBay, pero liviano**: sólo se descarga o compila lo que un proyecto
   pide, y nada queda encendido sin un proyecto activo.
5. **Docker opcional**: un tipo de proyecto «compose» que sólo arranca y detiene un
   `compose.*.yaml` existente y muestra su estado, para lo que de verdad necesite contenedores.
