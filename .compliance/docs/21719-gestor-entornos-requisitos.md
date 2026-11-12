# Gestor de entornos `.env` — requisitos de seguridad y datos (Ley 21.719)

**Producto:** Butake Stack (Butake SpA) · **Función:** entornos `.env` por sitio (Local, Pruebas,
Staging, Producción…) · **Fecha:** 2026-11-12 · **Alcance:** diseño previo a la implementación.

> Fuente: Ley 21.719, texto del Diario Oficial (13-dic-2024). Artículos citados: 3 e) y f)
> (responsabilidad y seguridad), 14 quáter (protección desde el diseño y por defecto), 14 quinquies
> (medidas de seguridad), 14 sexies (vulneraciones), 15 ter (evaluación de impacto).

## 1. Roles y encuadre

- **Butake SpA como fabricante de Butake Stack no es responsable ni encargado** de estos datos: la app
  corre sólo en el Mac del usuario, no envía `.env`, secretos ni datos de proyectos a Butake SpA ni a
  terceros (sus únicas conexiones son descargas de herramientas desde fuentes oficiales y la consulta de
  versiones en GitHub). Por eso no corresponde RAT, política de privacidad, DPA ni consentimiento
  **del producto** para esta función.
- **Quien usa Stack es responsable de sus propios sistemas.** Los `.env` no suelen contener datos
  personales, pero sí **credenciales que dan acceso a bases con datos personales** (en el ecosistema
  Butake, incluso datos de salud, que son sensibles). Un acceso no autorizado a esas credenciales puede
  terminar en una vulneración del Art. 14 sexies. Por eso el gestor es parte de las **medidas de
  seguridad** del responsable (Art. 3 f; Art. 14 quinquies) y debe diseñarse con protección por
  defecto (Art. 14 quáter).

## 2. Requisitos (obligatorios para publicar la función)

| id | Requisito | Fundamento |
|---|---|---|
| R1 | **Secretos sólo en el Llavero** de macOS: un ítem por sitio, entorno y clave; accesible sólo con el Mac desbloqueado y **sólo en este dispositivo** (sin sincronizar a iCloud). Nunca en el almacén JSON de Stack, registros, respaldos, vistas previas ni informes de error. | 14 quinquies a) y b) |
| R2 | **Secreto por defecto:** toda clave cuyo nombre sugiera credencial (`PASSWORD`, `SECRET`, `KEY`, `TOKEN`, `PRIVATE`, `DSN`, `CREDENTIAL`, `AUTH`, `SALT`, `CERT`, `PASS`) se guarda como secreto; el usuario puede cambiarlo, nunca al revés de forma automática. | 14 quáter (por defecto) |
| R3 | **Revelar o copiar un secreto exige autenticación local** (Touch ID o contraseña del Mac). Los valores se muestran enmascarados; lo copiado se marca como contenido oculto y se borra del portapapeles a los 60 s. | 14 quinquies b) |
| R4 | **Producción bloqueada por defecto.** Activarla exige autenticación, escribir el nombre del sitio y deja un aviso rojo permanente; con Producción activa, colas y scheduler del sitio **no arrancan solos**. Se recomienda que sus credenciales sean de sólo lectura. | 3 f); 14 quinquies |
| R5 | **Escritura segura del `.env`:** atómica, permisos 600, sólo dentro de la carpeta del sitio (sin enlaces simbólicos). Si `.env` no está en `.gitignore` o ya está versionado, **no se escriben secretos** y se avisa. | 14 quinquies b); 3 f) |
| R6 | **Sin fugas por el motor:** los valores viajan por la entrada estándar del proceso (nunca como argumentos visibles en `ps`), y ni errores ni el modo de depuración imprimen valores: sólo nombres de claves. | 14 quinquies b) |
| R7 | **Registro de auditoría local sin valores:** fecha, sitio, entorno, acción (crear, editar, revelar, copiar, activar, exportar, eliminar) y usuario de macOS; permisos 600; se conserva 180 días. Permite **acreditar** las medidas ante un incidente. | 14 quinquies (inciso final) |
| R8 | **Importación sin pérdidas ni copias en claro:** el `.env` actual pasa a ser el entorno "Local" (secretos al Llavero); no se dejan respaldos `.env.bak` en texto plano. | 14 quáter; 14 quinquies c) |
| R9 | **Compartir sin exponer:** exportar como plantilla sin valores secretos. **Descargar** un entorno con sus valores reales (`.env.<entorno>`) es una acción explícita: pide Touch ID o la contraseña del Mac (en Producción, siempre), se escribe con permisos 600, nunca a través de un enlace simbólico, dentro de un repositorio sólo si Git lo ignora, y queda en la auditoría sin valores. | 14 quinquies a) y b) |
| R10 | **Borrado completo:** eliminar un entorno o un sitio borra sus ítems del Llavero; nada queda huérfano. | 14 quáter (plazo de conservación) |
| R11 | **Respuesta a incidentes:** procedimiento documentado para Mac perdido o secreto filtrado (ver `21719-gestor-entornos-incidentes.md`). | 14 sexies |
| R12 | **Verificación periódica:** pruebas automáticas de que ningún valor aparece en el almacén, los registros ni las respuestas del motor; esta revisión se repite en cada release que toque la función. | 14 quinquies d) |

## 3. Regla de trabajo para agentes de IA

Los agentes que desarrollan Stack **no leen, copian ni registran valores** de `.env` reales: QA sólo con
proyectos temporales y valores ficticios.

## 4. Decisiones resueltas

- **EIPD:** no obligatoria para esta función (ver `21719-eipd-gestor-entornos.md`).
- **DPO:** no aplica a la función; el responsable designado de cada empresa usuaria sigue a cargo.
- **Transferencias internacionales:** no hay; nada sale del Mac.

---
*No constituye asesoría legal. Borrador fundado en la Ley 21.719 para cumplir sin abogado.*
