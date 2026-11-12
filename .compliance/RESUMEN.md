# Cumplimiento — Butake Stack

## Cambios vs última corrida (2026-11-12, diseño)
- **Avance:** los 10 controles quedan en «cumple» tras implementar R1 a R12. Puntaje 0,30 → 1,00.
- **Hallazgo corregido durante la implementación:** la autenticación reutilizaba un desbloqueo reciente
  del Mac con Touch ID (`touchIDAuthenticationAllowableReuseDuration`) y aprobaba sin preguntar.
  Ahora no se reutiliza, y Producción pide autenticación nueva cada vez (R3, R4).
- **Verificado con datos ficticios:** importar, crear (copia con secretos), activar, volver a Local
  (`.env` idéntico al original), permisos 600, `.env` ignorado por Git, auditoría sin valores,
  Producción bloqueada sin confirmación. El aviso de Touch ID al activar Producción apareció; la
  prueba de cancelarlo debe repetirse con la corrección.
- **Sin drift.**

---


**Corrida:** 2026-11-12 (primera) · **Commit:** 030f395 · **Marco:** Ley 21.719 · **Alcance:** gestor de
entornos `.env` por sitio, revisado **antes de implementarlo**.

## Postura
- Butake SpA no es responsable ni encargado de los datos que maneja esta función: todo queda en el Mac
  del usuario. No corresponden RAT, política, DPA ni consentimiento del producto para esta función.
- La función guarda **credenciales que abren sistemas con datos personales** (incluso de salud), así que
  es una **medida de seguridad** del responsable (Arts. 3 f, 14 quáter, 14 quinquies).
- **EIPD no obligatoria** (test del Art. 15 ter negativo). Sin transferencias internacionales.
- Puntaje de diseño: 0,30. Es esperable: los controles quedan en "falta" hasta implementarlos; la próxima
  corrida, tras la implementación, debe llevarlos a "cumple".

## Requisitos para publicar (R1 a R12)
Ver `docs/21719-gestor-entornos-requisitos.md`: secretos sólo en el Llavero y sólo en este dispositivo;
secreto por defecto; Touch ID para revelar, copiar o activar Producción; Producción bloqueada por
defecto y sin colas automáticas; `.env` atómico con permisos 600 y obligatorio en `.gitignore`; el motor
nunca imprime valores; auditoría local sin valores; importación sin copias en claro; exportar sin
secretos; borrado completo; procedimiento de incidentes; pruebas automáticas.

## Pendiente fuera del código
- RUT de Butake SpA (sólo para el estado; no afecta los requisitos).
- Recomendación organizativa: credenciales de Producción de sólo lectura en Macs de desarrollo.

## Próxima corrida
Al terminar la implementación y antes del release que la publique.

---
*No constituye asesoría legal. Borrador fundado en la Ley 21.719 para cumplir sin abogado.*
