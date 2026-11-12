# PHP propio: fabricación y distribución

Las compilaciones se publican con su SHA-256 en el release `runtimes` y se instalan desde Preparar Butake Stack o desde la página de PHP.

Butake Stack compila PHP desde fuentes originales y prepara paquetes propios. No incorpora
binarios ni código de otras herramientas de desarrollo. Los componentes de terceros conservan
sus licencias y avisos: «propio» describe la compilación y la integración de Butake, no una
autoría de PHP o de sus bibliotecas.

## Fabricación explícita

`scripts/php/VERSIONS` fija static-php-cli 2.8.5, su archivo fuente, pkg-config, Composer,
el paquete CA de Mozilla, Xdebug estable y Oniguruma mediante URL y SHA-256. Las extensiones
solicitadas están en `scripts/php/extensions.txt`. Se añade `mbregex` en la invocación de SPC:
es una opción de construcción necesaria para `mb_split()`, aunque no aparece como módulo
separado en `php -m`.

El constructor:

1. Comprueba las herramientas existentes. No instala herramientas ni acepta reparaciones de
   SPC. La instalación de dependencias del sistema es una operación aparte del titular.
2. Crea un directorio nuevo de compilación fuera del repo. Por defecto vive bajo
   `~/Library/Caches/Butake Stack/php-build/`; en QA se cambia con `BUTAKE_STACK_BUILD_ROOT`.
3. Descarga y verifica los archivos fijados. Usa el ejecutable SPC de la misma release para
   arrancar sin un PHP externo; extrae también la fuente de la etiqueta verificada.
4. Ejecuta `doctor`, descarga las dependencias solicitadas y compila CLI, FPM y Xdebug
   compartido. Limita la compilación a cuatro trabajos y apunta a macOS 14 arm64.
5. Comprueba versión, módulos, `mb_split()` y ausencia de dependencias dinámicas de Homebrew.
6. Instala en `runtimes/php/<serie>/`, conservando los avisos de terceros y escribiendo el
   manifiesto con hashes, fecha UTC, versión SPC y procedencia de las descargas.
7. Pide al motor generar `php.ini`, con límite de memoria, opcache y CA. Comprueba el archivo
   FPM de verificación con `php-fpm -t`, sin iniciar un servicio.
8. Conserva el registro y el inventario de fuentes con hashes; elimina el directorio de
   compilación tanto al terminar como al fallar.

Ejemplo de QA, siempre con almacenamiento temporal:

```bash
STACK_QA_ROOT="$(mktemp -d /tmp/butake-stack-php.XXXXXX)"
export BUTAKE_STACK_HOME="$STACK_QA_ROOT/store"
export BUTAKE_STACK_BUILD_ROOT="$STACK_QA_ROOT/work"
./scripts/php/build-php.sh 8.2
```

Se admiten 8.2 y 8.5. No se compilan versiones adicionales automáticamente. La pantalla
«Runtimes» pide confirmación y ejecuta el trabajo bajo el supervisor, con registro en vivo.
Los binarios instalados no se reemplazan silenciosamente.

## Paquetes para instalar sin recompilar

```bash
./scripts/php/package-php.sh "$BUTAKE_STACK_HOME/runtimes/php/8.2" "$PWD/build/runtimes"
```

Este paso comprueba los hashes y `mb_split()`, conserva licencias y produce un `.tar.gz`
por versión y arquitectura, junto con `catalog.json` (versión, tamaño, nombre y SHA-256).
La compresión y los metadatos del archivo son deterministas para un mismo runtime.

El catálogo local deja `download_url` en `null`: no publica, crea remotos, tags ni sube archivos.
Sirve para revisar los paquetes antes de elegir y autorizar su alojamiento. Preparar un
paquete no significa que su descarga desde la app ya esté disponible; la distribución y el
instalador de binarios se completan con las tareas correspondientes del plan.

## Aislamiento

El constructor no inspecciona proyectos ni archivos `.env`. Los procesos reciben ejecutables
y argumentos separados. Xdebug se entrega aparte y no se carga en `php.ini`.

Las comprobaciones de Gestión se ejecutan con un perfil macOS de sólo lectura, sin red,
con lectura de `.env*` y del Llavero bloqueada, cachés y almacenamiento temporales, SQLite
en memoria y puertos de prueba. Se descarta la salida general para evitar registrar datos
del proyecto. No se ejecutan migraciones ni se importan bases.
