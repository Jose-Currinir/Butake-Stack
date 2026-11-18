//! Starting texts of new skills (SKILL.md in Spanish). Portable frontmatter: `name`, `description`.
use super::model::fail;
use super::skill_file::quote;
use anyhow::Result;

const COMMITS: &str = "\
# Commits

Aplica estas reglas cada vez que prepares un commit en un repositorio.

## Reglas

- Mensaje en español, en modo imperativo o descriptivo, con el formato convencional:
  `tipo(área): resumen`. Tipos habituales: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`.
- El resumen cabe en una línea (unos 72 caracteres) y no termina en punto.
- Un commit trata un solo tema. Si el cambio mezcla temas, sepáralo en varios commits pequeños.
- Agrega un cuerpo solo cuando el porqué no es evidente; explica el motivo, no el listado de archivos.
- Sin coautoría de IA ni líneas de atribución en el mensaje.
- Si el repositorio define sus propias reglas (por ejemplo en `AGENTS.md`), esas mandan.

## Antes de confirmar

1. Revisa `git status` y `git diff` para saber exactamente qué entra.
2. Agrega los archivos por nombre; evita agregar todo sin mirar.
3. Corre las pruebas o validaciones del repositorio y confirma que pasan.
4. No hagas push ni publiques salvo que el usuario lo pida.

## Ejemplos

- `feat(proyectos): permitir mover un proyecto a otra carpeta`
- `fix: no perder el puerto al reiniciar el servicio`
- `docs: aclarar cómo se restauran las copias`
";

const PUBLISH_APP: &str = "\
# Publicar una app

Lista de verificación para compilar, firmar y publicar una app móvil desde este equipo, para iOS y
Android. Ajusta los nombres a tu proyecto.

## Reglas

- Todo se hace en local: nada de servicios que reciban el código o las claves.
- El material de firma (certificados, perfiles, almacén de claves y sus contraseñas) se pide a la
  Bóveda de Stack cuando hace falta. Nunca escribas claves ni contraseñas en el repositorio, en
  archivos de configuración versionados, en el historial ni en este texto.
- Confirma con el usuario antes de subir cualquier compilación a una tienda.

## Antes de empezar

1. Árbol limpio y rama correcta; las pruebas pasan.
2. Sube la versión y el número de compilación en el lugar que use el proyecto.
3. Actualiza las notas de la versión.

## iOS

1. Verifica que el certificado de distribución y el perfil de aprovisionamiento están disponibles
   en el Llavero; si faltan, pídelos a la Bóveda.
2. Genera el archivo de la app en modo release con la herramienta de compilación del proyecto.
3. Firma con el certificado de distribución y el perfil correspondiente.
4. Exporta el paquete (`.ipa`) y revisa que la versión y el identificador son los esperados.
5. Súbelo a App Store Connect con la herramienta de línea de comandos de Apple, con confirmación.

## Android

1. Obtén el almacén de claves y sus contraseñas desde la Bóveda hacia el entorno del proceso; no a
   un archivo versionado.
2. Genera el paquete (`.aab`) en modo release con Gradle.
3. Firma el paquete con la clave de subida y verifica la firma.
4. Súbelo a la consola de la tienda en la pista que indique el usuario (interna, cerrada o producción).

## Después

1. Etiqueta la versión en el repositorio si el usuario lo pide.
2. Guarda el número de compilación publicado y anota cualquier incidencia.
3. Borra de la carpeta de trabajo los archivos de firma temporales.
";

/// The whole SKILL.md for a template.
pub fn render(template: &str, name: &str, description: &str) -> Result<String> {
    let body = match template {
        "blank" => format!("# {name}\n\n## Cuándo usarla\n\n## Pasos\n\n## Notas\n"),
        "commits" => COMMITS.to_string(),
        "publish-app" => PUBLISH_APP.to_string(),
        _ => return fail("invalid_request"),
    };
    Ok(format!(
        "---\nname: {}\ndescription: {}\n---\n\n{body}",
        quote(name),
        quote(description)
    ))
}
