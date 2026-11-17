# Diagnóstico y operación

## Primer inicio y puertos

El estado de la barra inferior muestra por separado si el supervisor responde, si el agente de
sesión está cargado y qué proceso ocupa los puertos. Instala los lenguajes y servicios
necesarios desde el asistente de configuración (Ayuda) y revisa Ajustes › Red para ver los
estados de HTTP, HTTPS, QUIC y DNS. Si un puerto está ocupado, identifica al propietario y
elige cómo resolver el conflicto. Stack no detiene aplicaciones de terceros sin confirmación.

Si un dominio local no resuelve, revisa Ajustes › Red. La configuración del resolver y la
confianza de la CA local se solicitan por separado con el diálogo de administrador de macOS.
Caddy debe haber generado la CA antes de confiar en ella.

## Operación sin red

Los proyectos, servicios, registros y catálogos ya instalados funcionan localmente. Descargar
lenguajes, consultar versiones nuevas, clonar repositorios remotos y compartir por túnel
requieren red. Para KMP, Django, FastAPI y Rust no hace falta que el lenguaje lea el `.env`:
con «Pasar el entorno activo a los procesos» (activado por defecto en Entornos) sus procesos
inician con las variables del entorno activo que Stack escribió. Stack propone nombres de claves
y puertos, y escribe el archivo cuando activas un entorno que gestionas desde la app.

Ajustes › Herramientas controla la activación de Correo y Dumps. Sus receptores necesitan el
supervisor. Desactivar una herramienta conserva los datos de Correo. Los dumps se mantienen en
memoria durante la sesión del daemon, con un máximo de 300 entradas o 8 MiB de JSON.

## Registros

Cada línea que escribe un proceso supervisado pasa por un filtro antes de llegar al archivo
(`logs/<proceso>.log`) o a la vista Registros. El filtro oculta **valores**, no líneas: la línea
se conserva y cada valor secreto se reemplaza por `[oculto]`. Así una línea que solo nombra
variables (un servidor que lista sus módulos apagados o avisa que falta `API_KEY`) queda intacta.
Se oculta:

- el valor asignado a un nombre sensible: `NOMBRE=valor`, `nombre: valor`, `"nombre": "valor"`,
  `'nombre' => 'valor'`, `--nombre=valor` y `--nombre valor`. El valor llega hasta el final de la
  línea salvo que siga otra asignación (`DB_PASSWORD=… DB_HOST=127.0.0.1` conserva el host);
- el valor completo de las cabeceras `Authorization`, `Proxy-Authorization`, `Cookie` y
  `Set-Cookie`, y el de `X-…-Key` o `X-…-Token`;
- la contraseña de una URL con credenciales (`postgres://usuario:[oculto]@127.0.0.1/base`);
- los JWT y las claves con prefijos conocidos (`sk_live_`, `ghp_`, `AKIA`, `xoxb-`…) en cualquier
  parte de la línea;
- una palabra de aspecto aleatorio (16 caracteres o más, con letras y dígitos) justo después de un
  nombre sensible (`token 9f8e…`);
- todas las líneas de un bloque de clave privada PEM.

Un nombre es sensible si contiene `PASSWORD`, `PASSWD`, `PWD`, `PASS`, `SECRET`, `TOKEN`, `AUTH`,
`CREDENTIAL`, `PRIVATE`, `COOKIE`, `SESSION`, `SIGNATURE`, `SALT` o `DSN`, o termina en `KEY`
(`_` y `-` valen igual). Ante la duda se oculta el valor: `token: expired` queda como
`token: [oculto]`. El filtro está en `engine/src/daemon/redact.rs` y sus pruebas usan valores
centinela que nunca deben sobrevivir.

## Copias y recuperación

Ajustes › Avanzado exporta y restaura la configuración de Stack para reconstruir un entorno.
Bóveda › Exportar crea un archivo cifrado con los datos de la Bóveda. Los datos de cada
servicio de bases de datos tienen su propio respaldo. Prueba una restauración con una carpeta
temporal y datos de prueba antes de usar una copia como respaldo operativo.

Para actualizar, Stack valida la suma publicada, la firma Developer ID y la aceptación de
Gatekeeper. El reemplazo espera que cierres la app normalmente. Si el instalador no puede
escribir en la carpeta de instalación, descarga el DMG desde la página oficial e instálalo
según el README.

## Carpeta de datos y su traslado

Los datos de Stack viven en `~/Library/Application Support/Stack`. Una instalación que empezó
cuando el producto tenía otro nombre los tiene en `~/Library/Application Support/Butake Stack` y
los sigue usando sin tocarlos: el motor (`Store::resolve`) y la app (`Folder.resolveData`) eligen,
en este orden, `BUTAKE_STACK_HOME`; la carpeta nueva si ya tiene datos (`stack.json` o
`projects/`); la anterior si existe; y si no hay ninguna, la nueva. Nada se mueve solo.

**Mover los datos.** Ajustes › Avanzado › «Mover los datos a la carpeta Stack…» muestra el plan y
pide confirmación. Desde la terminal, con la app cerrada:

```bash
STACK="/Applications/Stack.app/Contents/Resources/butake-stack"
"$STACK" migrate-data --plan      # qué haría: tamaño, espacio, qué se detiene, qué rutas cambian
"$STACK" migrate-data --confirm   # lo hace; responde en JSON y sale con 1 si falló
```

Pasos: comprueba el espacio (en el mismo disco, la copia son clones APFS: instantánea y sin
espacio extra) y que la carpeta nueva no exista; detiene todo lo supervisado en su orden (MySQL
espera hasta 120 s), saca el agente de launchd (`launchctl bootout`) y espera a que el supervisor
suelte la carpeta; comprueba con `lsof +D` que ningún proceso tiene archivos abiertos ahí y que
cada base se apagó limpia (sin `run/*.pid`, `run/pids/*`, `postmaster.pid` ni `mongod.lock` con
contenido); hace la copia de seguridad `Butake Stack (copia AAAAMMDD-HHMMSS)` junto a la carpeta y
la verifica entrada por entrada (y por SHA-256 lo que no se pudo clonar); renombra la carpeta;
reescribe las rutas absolutas que la nombraban, guardando el original de cada una: archivos de
texto de la carpeta (configuración de servicios, JSON, enlaces internos; nunca `data/`, `logs/`,
`mail/`, `vault/` ni `aws-backups/`), el plist del LaunchAgent, el bloque de `~/.zprofile`, las
líneas `credential_process` de `~/.aws/config` que apunten dentro de la carpeta, los enlaces de
`~/.local/bin`, los enlaces de las carpetas de las IA a las skills de Stack (herramienta Skills) y el `.venv` (`pyvenv.cfg` y enlaces) de los proyectos; vuelve a cargar el agente
(`launchctl bootstrap`) y comprueba que cada proceso que corría corre y que cada servicio
responde en su puerto (MySQL saluda, Redis contesta PING). Si un paso falla, deshace lo hecho:
detiene, repone cada original byte a byte, devuelve la carpeta a su nombre y vuelve a iniciar lo
que corría. El diario `migration.json` (dentro de la carpeta) hace que repetir la orden no haga
nada si ya terminó y que una ejecución cortada a medias se termine al lanzarla otra vez.

Tiempo: lo que tarden en detenerse y volver a iniciarse los servicios (de segundos a unos dos
minutos con MySQL) más unos segundos de clonado. La copia de seguridad queda hasta que la borres.

**Volver atrás a mano** (si la app no puede): detén Stack (`launchctl bootout
gui/$(id -u)/cl.butake.stack.daemon`), renombra `~/Library/Application Support/Stack` a `Butake
Stack` (o, si dudas de su estado, aparta esa carpeta y renombra la copia `Butake Stack (copia …)`
a `Butake Stack`), cambia en `~/Library/LaunchAgents/cl.butake.stack.daemon.plist` la ruta de
`BUTAKE_STACK_HOME`, en `~/.zprofile` la de `PHPRC` y vuelve a cargar el agente con `launchctl
bootstrap gui/$(id -u) ~/Library/LaunchAgents/cl.butake.stack.daemon.plist`. Los enlaces de
`~/.local/bin` se rehacen al volver a elegir la versión de cada lenguaje en la terminal, y los
perfiles de AWS con «Reparar…».

**Al instalar Stack.app sobre una copia con el nombre anterior.** El agente y los perfiles de AWS
con Llavero apuntan al motor de la app con la que se activaron: apaga y vuelve a encender
«Iniciar con la sesión» (Ajustes › General) y usa «Reparar…» en cada perfil de AWS antes de
borrar la app anterior.

## Desarrollo y QA

Cadena de validación, pruebas, QA visual con un almacén temporal y dobles de programas externos:
[pruebas-y-qa.md](pruebas-y-qa.md). La app compilada localmente se firma como se explica en «Firma».

## Firma

macOS reconoce una app por su **requisito designado**. El Llavero guarda, para cada dato, qué
apps pueden leerlo sin preguntar; «Permitir siempre» agrega ese requisito. Con firma ad hoc el
requisito es la huella de esa compilación exacta, así que cada actualización volvía a pedir la
contraseña por cada dato. `scripts/build-native.sh` firma (con `scripts/signing.sh`) el motor
(`cl.butake.stack.engine`) y luego la app (`cl.butake.stack.native`) con una identidad del
llavero y un requisito fijo, sin derechos (entitlements):

```
identifier "cl.butake.stack.native" and anchor apple generic and certificate leaf[subject.OU] = "<equipo>"
```

Es decir: ese identificador, un certificado emitido por Apple y el equipo de la identidad. No
depende de la huella del binario ni del certificado concreto, así que sigue igual entre
compilaciones y al renovar el certificado; una firma Developer ID del mismo equipo también lo
cumple si conserva el identificador.

**Qué identidad.** En este orden: `STACK_SIGN_IDENTITY` (huella SHA-1 o nombre exacto de una
identidad de `security find-identity -v -p codesigning`; `-` fuerza ad hoc); la huella fijada en
`.stack-sign-identity` en la raíz del repositorio (local, no versionado) si sigue siendo válida;
si no, la identidad «Apple Development» válida que vence más tarde (a igual fecha, la de huella
menor), que queda fijada en ese archivo. Sin ninguna, firma ad hoc y lo avisa. El script imprime
la identidad usada. Para elegir otra, borra `.stack-sign-identity` o define la variable. La
primera vez, macOS puede pedir permiso para que `codesign` use la clave privada; se autoriza una
vez («Permitir siempre»). Comprobación: `codesign --verify --deep --strict` y `codesign -d -r-`
(el requisito debe ser idéntico entre compilaciones).

**Qué pasa con el Llavero al cambiar de identidad.** Los datos guardados no se pierden ni se
vuelven ilegibles: al cambiar el requisito, macOS pide la contraseña del Mac una vez por dato y
con «Permitir siempre» agrega la nueva firma. Pasa lo mismo al pasar de ad hoc a una identidad
estable (la app lo avisa una sola vez) y al cambiar a una identidad de **otro equipo**; entre
identidades del mismo equipo no pide nada. Los datos que creó otra firma no siempre se pueden
borrar desde la app (macOS los reserva a su creador): quedan sin uso y se pueden borrar en
Acceso a Llaveros buscando «Stack ·». La clave maestra de la Bóveda está en el llavero de inicio
de sesión (ver `docs/boveda-formato.md`) y sigue esta misma regla.

**Datos del Llavero.** Secretos de Entornos: un ítem por proyecto y entorno (servicio
`cl.butake.stack.env`, cuenta `proyecto/entorno`, JSON nombre → valor; los nombres, nunca los
valores, van en sus atributos). Abrir Entornos solo lee atributos; los valores se leen al revelar,
copiar, guardar, duplicar, descargar o activar, una vez por entorno. Los ítems por variable de
versiones anteriores (`proyecto/entorno/CLAVE`) se migran la primera vez que se leen: se lee cada
uno, se escribe y comprueba el ítem único y solo entonces se borran; si se deniega el permiso no
cambia nada y se reintenta después. Contraseñas de bases (`cl.butake.stack.db`), frases de claves
SSH (`cl.butake.stack.ssh-key`) y claves de AWS (`cl.butake.stack.aws`, escritas y leídas solo por
el motor) siguen con un ítem por conexión, clave o perfil: se leen de a uno, al usarlos.
