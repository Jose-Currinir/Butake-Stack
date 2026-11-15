# Bóveda: almacenamiento y formato `.butakevault`

La herramienta **Bóveda** guarda lo que se usa para firmar y desplegar cada app (llaveros Android,
certificados y perfiles de iOS, claves de App Store Connect, archivos de Firebase, cuentas de
servicio, claves SSH, `.env` de servidores, tokens y notas), organizado como el respaldo maestro
`3.CLAVES-APPS`. Todo vive en la app nativa (`native/Sources/ButakeStack/Vault/`); el motor
Rust no lee ni escribe la bóveda, y la exportación de «Mi entorno» sigue sin secretos.

## En disco

```
~/Library/Application Support/Stack/vault/            (o $BUTAKE_STACK_HOME/vault/)   0700
  vault.json        formato, versión y el id de su clave en el Llavero (sin secretos)   0600
  index.bin         AES-256-GCM del índice: apps, servicios, elementos, campos, notas    0600
  blobs/<uuid>.bin  AES-256-GCM de cada archivo guardado                                 0600
  access.log        JSON por línea: fecha, usuario, acción, id del elemento               0600
  tmp/              copias de corta vida para herramientas locales (keytool); se borran  0700
```

- Cada caja AES-GCM es `nonce (12) · cifrado · etiqueta (16)` con nonce aleatorio, y autentica un
  contexto: `butake-vault/index/v1` para el índice y `butake-vault/blob/<uuid>` para cada archivo, de
  modo que un archivo no puede cambiarse por otro.
- El registro de accesos sólo guarda ids (UUID): los nombres y valores siguen cifrados en el índice.
- Al importar o agregar un archivo se calcula su SHA-256, se cifra, se vuelve a leer y se compara
  antes de tocar el índice. El origen nunca se mueve ni se borra.

## Clave maestra

256 bits aleatorios, en el Llavero de macOS (servicio `cl.butake.stack.vault`, cuenta
`master/<keyId>`), sólo de este dispositivo y sin sincronizar.

- Si la app está firmada con derecho al Llavero de protección de datos, el elemento lleva
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` y `SecAccessControl` con `.userPresence`: leerlo
  exige Touch ID o la contraseña del Mac.
- Stack se firma sin derechos (ad hoc o con una identidad «Apple Development», ver
  `docs/operations.md`, «Firma»), así que ese Llavero no está disponible (`errSecMissingEntitlement`,
  comprobado con ambas firmas); la clave va al Llavero de inicio de sesión con
  `WhenUnlockedThisDeviceOnly` y la app pide presencia (`LAContext`, `deviceOwnerAuthentication`, sin
  reutilizar desbloqueos recientes) antes de leerla. Cambiar la identidad de firma no la mueve ni la
  vuelve ilegible: macOS pide la contraseña del Mac una vez y, con «Permitir siempre», recuerda la
  nueva firma. Lo cifrado depende solo de la clave, nunca de la firma.
- Desbloquear pide presencia. La sesión se cierra tras 5 minutos sin uso, al dormir, al apagar la
  pantalla, al bloquearla o al iniciar el protector. Revelar y copiar piden presencia (una
  confirmación vale 60 s); guardar un archivo, exportar y descargar la piden siempre.
- Copiar marca el valor como `org.nspasteboard.ConcealedType` y lo borra a los 30 s si sigue ahí.
- Con `BUTAKE_STACK_HOME` (QA, pruebas) se usa el servicio `cl.butake.stack.vault.qa`.

## `.butakevault` (versión 1)

```
"BUTAKEVT" (8 bytes ASCII)
versión (1 byte) = 0x01
largo del encabezado (UInt32, big endian)
encabezado (JSON UTF-8)
caja AES-256-GCM: nonce (12) · cifrado · etiqueta (16)
```

Encabezado:

```json
{"format": "butake-vault", "version": 1, "kdf": "pbkdf2-sha256", "iterations": 600000,
 "salt": "<16 bytes en base64>", "cipher": "aes-256-gcm", "created": "2026-11-12T22:00:00Z",
 "scope": "all | <carpeta de la app o servicio>", "containers": 2, "items": 9}
```

- Clave: PBKDF2-HMAC-SHA256 (CommonCrypto) de la contraseña con `salt` e `iterations` (al importar se
  aceptan entre 100 000 y 10 000 000). Contraseña mínima: 12 caracteres.
- Datos adicionales autenticados: todos los bytes antes de la caja (firma, versión, largo y
  encabezado), así que alterar el encabezado también hace fallar el descifrado.
- Contenido descifrado (JSON): `containers` y `items` como en el índice, y `blobs`, un objeto
  `uuid → bytes en base64`. Al importar se verifica el SHA-256 de cada archivo.
- Una contraseña incorrecta y un archivo alterado dan el mismo error (GCM no los distingue).
- Al importar, las apps y servicios se emparejan por nombre de carpeta y se omiten los archivos que ya
  están (mismo SHA-256).

## Campo `project` (enlace con un proyecto)

Cada app (`containers[]` con `kind: "app"`) puede llevar `"project": "<id del proyecto de Stack>"`, que
el usuario elige en «Proyecto» al crear o editar la app (con una sugerencia por nombre o identificador
que siempre confirma). Va dentro del índice cifrado y del contenido cifrado de `.butakevault`; nunca en
`vault.json`, el encabezado ni el registro de accesos.

- Es opcional y solo crece el formato: la versión sigue en 1. Un índice o un `.butakevault` sin el campo
  se abre igual (la app queda sin proyecto), y una versión anterior de Stack ignora el campo al leer.
  Sin proyecto, el campo no se escribe.
- Los servicios (`_SERVICIOS`) no se enlazan. Un id que ya no existe en este Mac se muestra como
  «Proyecto no encontrado» y se puede cambiar; importar un respaldo conserva el campo tal cual.
- Con la Bóveda desbloqueada, el Resumen del proyecto lista nombre, tipo, entorno y vencimiento de los
  elementos de sus apps, sin valores. Bloqueada, el índice no está en memoria y el Resumen solo ofrece
  «Desbloquear…»; desactivada, «Activar en Ajustes…».

## Mover a Entornos o a Claves SSH

Los elementos `envFile` y `sshKey` que ya existen se pueden mover, siempre por acción explícita: hoja con
vista previa (solo nombres de variables y si se crean o reemplazan), confirmación y presencia nueva
(Touch ID o contraseña del Mac, la misma comprobación de la Bóveda).

- `.env` → Entornos: el archivo se descifra en memoria; los valores van al ítem del entorno en
  el Llavero de Entornos (`cl.butake.stack.env`, uno por proyecto y entorno) y después el motor (`envMergeSecrets`) agrega o reemplaza las claves como
  secretas, sin valor en su almacén, y anota «mover» por clave en la auditoría de Entornos (sin
  valores). Si el motor falla, el Llavero vuelve a como estaba. Se relee todo antes de dar el éxito.
- Clave SSH → Claves SSH: copia de corta vida en `tmp/` de la bóveda (0600 dentro de 0700, se borra al
  terminar), importada con `sshKeyImport`; su frase de paso, si la Bóveda la tiene, va al Llavero de
  Claves SSH. Se comprueba en la lista de claves (y contra la huella leída, si la hay).
- El registro de accesos anota `moveToEnvironments` o `moveToKeys` con el id del elemento. El original
  nunca se elimina solo: tras comprobar, la hoja ofrece «Eliminar…» con su propia confirmación.

## Carpeta en claro (respaldo maestro)

«Descargar como carpeta» crea siempre una carpeta nueva `3.CLAVES-APPS` (o `3.CLAVES-APPS 2`…):

```
3.CLAVES-APPS/
  <Nombre app> (<bundle id>)/README.md, android/, ios/, server/, terceros/
  _SERVICIOS/<servicio>[/<cuenta>]/README.md y sus archivos
```

- `README.md` (generado): qué hay, vencimientos, metadatos y variables de entorno sugeridas; sin valores.
- Los campos de un elemento van junto a su archivo como `<archivo>.datos.txt` (líneas de dotenv con
  comentarios `# <rol>[ secreto]: <etiqueta>`, `# tipo:`, `# entorno:` y notas en líneas `#| `), y
  se vuelven a leer al importar esa carpeta.
- «Importar carpeta» acepta la carpeta maestra, una app, `_SERVICIOS` o un servicio; muestra una vista
  previa para elegir tipo, sección y entorno, sólo lee el origen y omite enlaces simbólicos, archivos
  ocultos del sistema y archivos de más de 20 MB. Cada `<cuenta>` de un servicio es una cuenta de ese
  servicio (campo opcional `account` del elemento), no un servicio aparte; una carpeta sin nada que
  importar no crea nada y lo que queda fuera se resume por categoría (ver
  [herramientas/boveda.md](herramientas/boveda.md#qué-entra-al-importar-una-carpeta)). El índice guarda ese resumen en `lastImport` (solo rutas
  relativas, motivos y cuentas). Ambos campos son opcionales: una versión anterior los ignora.
- La descarga ofrece dos estructuras: por partes de Stack (la de arriba) o por plataforma y entorno, como
  un respaldo real (`03-IOS/PROD/`, `04-ANDROID/QA/`…, ver abajo). Las dos se vuelven a importar igual.

## Respaldo real por plataforma y entorno

«Importar carpeta» también entiende la forma de un respaldo de claves real:

```
<respaldo>/<app> (<bundle>)/{01-API,02-WEB,03-IOS,04-ANDROID,05-TERCEROS}/{QA,PROD}/…
<respaldo>/<app> (<bundle>)/99-HISTORICO-TRANSICION/…      histórico
…/_archive/…, …/backups/…                                  archivados y respaldos
<respaldo>/_SERVICIOS/{apple-signing,apple-appstore,apple-apns,google-play,gcp}/…
```

- Carpetas de plataforma: `NN-API` y `NN-WEB` → Servidor, `NN-IOS` → iOS, `NN-ANDROID` → Android,
  `NN-TERCEROS` → Terceros (además de `android/`, `ios/`, `server/`, `terceros/`). `QA` (y `staging`, `test`,
  `preprod`, `dev`) → Preproducción; `PROD` → Producción.
- Quedan listados **sin marcar**, aparte en la vista previa: `99-HISTORICO*`, `_archive`, `backups`,
  volcados (`.dump`, `.sql`, `.sql.gz`, `.contenido.txt`, `.bak`), cualquier `.env` (va en los Entornos del
  proyecto) y las claves SSH (Ajustes › Claves SSH). Se pueden marcar a mano, salvo los `.env` y las SSH.
- **Duplicados:** el mismo contenido (SHA-256) en varias carpetas entra una vez; si las copias están en
  entornos distintos, el elemento queda sin entorno (vale para los dos). Las demás copias aparecen como
  «Repetido» con la ruta de la primera.
- **Contraseñas y datos asociados**, siempre dentro de la misma carpeta. Se leen al importar y van
  directo a los campos (secretos) del elemento; la vista previa sólo dice «Contraseña asociada», nunca el
  valor, y no quedan en registros, auditoría ni mensajes:
  - `X.p12.pass`, `.clave`, `.password`, `.pwd` (o `X-pass.txt`) → contraseña de `X.p12` (o del llavero
    `X.jks`, como contraseña del almacén). Se usa la primera línea, sin su salto.
  - `CREDENTIALS.txt`, `credenciales.txt`, `keystore.properties`, `key.properties` junto a un llavero →
    contraseña del almacén, alias y contraseña de la llave («Key password: la misma» toma la del almacén).
  - `fastlane.env` (o `.env.fastlane`) junto a un `.p8` → Key ID e Issuer ID; el `.p8` queda como clave de
    App Store Connect. El archivo no se importa.
  - `NOMBRE_EN_MAYUSCULAS.txt` de una línea (`FIREBASE_APP_ID.txt`) → un token sin archivo, con su variable.
  - Si el dueño no es seguro (ningún archivo con ese nombre y un solo certificado o llavero en la carpeta;
    varios llaveros y un `CREDENTIALS.txt` que no nombra ninguno), la asociación sólo se **propone**: la
    vista previa muestra «Usar <archivo> para este archivo (campos)» sin marcar, y sin la marca no se lee.
- Tipos que da la carpeta: un `.p8` bajo una carpeta `apns`/`push` es **Clave APNs**; un `.key` PEM (o un
  `.pem` junto a su `.cer`/`.p12`, o en iOS) es **Llave de certificado**, no clave SSH.

## Firma (por app y entorno)

Cada app tiene «Firma», que cruza lo guardado para Preproducción o Producción (lo que no tiene entorno
vale para los dos) y dice por fila **Listo**, **Vence pronto** (30 días), **Falta** o **No calza**, con qué
hacer. Sólo usa nombres, fechas, paquetes y huellas públicas; nunca un valor.

- Android: llavero (alias y huella; sin contraseña o sin Java, falta), `google-services.json` del paquete de
  la app (antes de Producción también `<bundle>.<sufijo>`), cuenta de servicio de Google Play (de la app o de
  `_SERVICIOS/google-play`) y `FIREBASE_APP_ID` de Android del mismo proyecto de Firebase.
- iOS, por cada bundle de sus perfiles (app, widget, reloj): el perfil, su vencimiento y si **incluye** un
  certificado cuyo `.p12` (o `.cer` con su llave) está en la Bóveda, comparando SHA-1; en Producción no
  calza un perfil de desarrollo ni con notificaciones de desarrollo. La clave de App Store Connect con Key ID
  e Issuer ID (de la app o de `_SERVICIOS/apple-appstore`) y `GoogleService-Info.plist` del bundle.
- «Volver a leer los archivos» relee los metadatos de la app y de los servicios (útil para lo importado
  antes de que Stack leyera los certificados de los perfiles). El Resumen del proyecto enlazado muestra la
  misma información resumida por entorno.

## Metadatos leídos localmente

| Tipo | Qué se lee |
|---|---|
| `.mobileprovision` | CMS → plist en memoria (`CMSDecoder`): vencimiento, equipo, App ID, tipo, dispositivos, SHA-1 de los certificados que incluye y capacidades (App Groups, HealthKit, notificaciones, Sign in with Apple) |
| `.p12` / `.cer` | `SecPKCS12Import` sólo en memoria con su contraseña: vencimiento, titular, Team ID, SHA-1 |
| `google-services.json` | proyecto, número de proyecto, paquetes |
| `GoogleService-Info.plist` | proyecto, bundle id, remitente |
| Cuenta de servicio | correo y proyecto; nunca `private_key` |
| `AuthKey_<ID>.p8` | Key ID desde el nombre (clave de App Store Connect o APNs) |
| Llave de certificado (`.key`) | sólo el tipo, de su primera línea; nunca la llave |
| Llavero Android | con el `keytool` del JDK de Stack o, si no hay, del JDK del sistema (`/usr/libexec/java_home`; contraseña por variable de entorno, `-storepass:env`): alias, titular, SHA-1, SHA-256, vencimiento; sin JDK lo dice |
| `.env` | cantidad y nombres de variables, nunca valores |
| Clave SSH pública | tipo, huella SHA-256, comentario |

Se avisa lo vencido y lo que vence en 30 días.

Los tipos `envFile` (`.env`) y `sshKey` siguen siendo válidos en el índice y en `.butakevault`: los
elementos que ya existen se leen, revelan, exportan e importan igual. La app ya no los crea (ni al
agregar, ni al arrastrar, ni al importar una carpeta): los `.env` van en los Entornos de cada proyecto
y las claves SSH de Stack en Ajustes › Claves SSH.

## QA

Con una compilación de depuración, `BUTAKE_QA_WINDOW=1` y un `BUTAKE_STACK_HOME` temporal,
`BUTAKE_QA_VAULT=<carpeta>` abre la bóveda desbloqueada con el servicio de Llavero de QA, importa esa
carpeta la primera vez y acepta `BUTAKE_QA_VAULT_SELECT`, `_SEARCH`, `_SHEET`, `_REVEAL`, `_PROJECT`, `_LOCK`, `_MOVE` (lo movido queda en
memoria, nunca en el Llavero) y
`BUTAKE_QA_SNAPSHOT=<png>` (ver `QA/VaultQA.swift`). `BUTAKE_QA_VAULT_BACKUP=<carpeta>` importa un respaldo
por plataforma y entorno en lugar de la carpeta anterior y `BUTAKE_QA_VAULT_SHEET=signing` abre «Firma»
(`BUTAKE_QA_VAULT_STAGE=test|prod`).

Los tipos `certificateKey` (llave de certificado) y `apnsKey` (clave APNs) son nuevos y el formato sigue en
la versión 1: en `kind` se escribe un tipo que toda versión conoce (`file` y `appStoreKey`) y el tipo real va
en `kindDetail`, así que una versión anterior de Stack abre el índice o el `.butakevault` igual. Un tipo que
esta versión no conoce se lee como «Otro archivo» en vez de dejar el índice sin abrir.
