# Procedimiento: Mac perdido o secreto filtrado (gestor de entornos)

Fundamento: Art. 14 sexies, Ley 21.719 (reportar vulneraciones sin dilaciones indebidas y registrarlas).

1. **Contener (de inmediato).** Rotar las credenciales de los entornos expuestos, empezando por
   Producción y Staging: claves de base de datos, `APP_KEY`, tokens de API, llaves de correo y nube.
   Revocar sesiones y tokens de acceso del Mac afectado.
2. **Evaluar.** Revisar los registros de acceso de los sistemas cuyas credenciales se expusieron:
   ¿hubo acceso no autorizado a datos personales? ¿de qué categorías y a cuántos titulares?
3. **Reportar.** Si hay riesgo razonable para los titulares: reporte a la Agencia por el medio más
   expedito y sin dilaciones indebidas. Si hay **datos sensibles** (por ejemplo, salud), de niños
   menores de 14 años o financieros: comunicar también a cada titular, en lenguaje claro.
4. **Registrar.** Anotar en el registro de vulneraciones de la empresa: naturaleza, efectos,
   categorías de datos, número aproximado de titulares y medidas adoptadas.
5. **Prevenir.** Revisar el registro de auditoría local de Stack (R7) para entender qué entornos
   estaban guardados y cuándo se activaron, y corregir la causa.

---
*No constituye asesoría legal. Borrador fundado en la Ley 21.719 para cumplir sin abogado.*
