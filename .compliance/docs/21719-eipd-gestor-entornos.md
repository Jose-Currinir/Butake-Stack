# EIPD — Gestor de entornos `.env` de Butake Stack: test de obligatoriedad

**Fecha:** 2026-11-12 · **Tratamiento evaluado:** guardar y aplicar entornos `.env` por sitio en el Mac del usuario.

> Art. 15 ter, Ley 21.719: la evaluación es obligatoria si es probable un alto riesgo y siempre en los
> casos a) a d).

## Test del Art. 15 ter
- [ ] a) Evaluación sistemática de aspectos personales, perfiles o decisiones automatizadas con efectos jurídicos. **No:** la función no evalúa personas.
- [ ] b) Tratamiento masivo o a gran escala. **No:** guarda configuración de proyectos de un solo usuario, en su propio Mac.
- [ ] c) Observación o monitoreo sistemático de una zona de acceso público. **No.**
- [ ] d) Datos sensibles en hipótesis de excepción del consentimiento. **No:** la función no trata datos sensibles; guarda credenciales.

**Resultado: la EIPD no es obligatoria.** El riesgo relevante es de **seguridad**: las credenciales
(sobre todo las de Producción) dan acceso a sistemas que sí pueden tener datos personales y sensibles.
Ese riesgo se mitiga con los requisitos R1 a R12 (`21719-gestor-entornos-requisitos.md`).

| Riesgo | Prob. | Impacto | Mitigación |
|---|---|---|---|
| Robo o pérdida del Mac con credenciales | Baja | Alto | R1 (Llavero, sólo este dispositivo), R3, R11 |
| Secreto filtrado a Git | Media | Alto | R5 (`.gitignore` obligatorio), R9 |
| Operar Producción por error desde local | Media | Alto | R4 |
| Secreto en registros o capturas | Baja | Medio | R1, R6, R12 |

Riesgo residual: aceptable con R1 a R12 implementados.

---
*No constituye asesoría legal. Borrador fundado en la Ley 21.719 para cumplir sin abogado.*
