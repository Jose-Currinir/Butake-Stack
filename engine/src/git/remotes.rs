//! Remotes: clone and create repositories, publish local branches (never forced), explain access
//! failures and build the link to a new pull request. URLs leave the engine without credentials.
use super::actions::validate_branch;
use super::protection::{main_protected, primary_branch};
use super::runner::{error, git, GitError, Result};
use std::path::Path;

/// `url` without the user and password of an `http(s)://user:token@host` address (a token pasted
/// into a remote URL must not reach the app); other transports only lose a password.
pub fn without_credentials(url: &str) -> String {
    let Some((scheme, rest)) = url.split_once("://") else {
        return url.to_string();
    };
    let authority_end = rest.find('/').unwrap_or(rest.len());
    let (authority, path) = rest.split_at(authority_end);
    let Some((user, host)) = authority.rsplit_once('@') else {
        return url.to_string();
    };
    let web = scheme.eq_ignore_ascii_case("http") || scheme.eq_ignore_ascii_case("https");
    match (web, user.split_once(':')) {
        (true, _) => format!("{scheme}://{host}{path}"),
        (false, Some((name, _))) => format!("{scheme}://{name}@{host}{path}"),
        (false, None) => url.to_string(),
    }
}

/// Only network transports a user would paste: https, ssh and scp-like `git@host:path`.
/// Rejects `ext::`, `file://`, option-like values and anything with spaces or control characters.
pub fn validate_clone_url(url: &str) -> Result<()> {
    let ok_chars = !url.is_empty()
        && url.len() < 2_048
        && !url.starts_with('-')
        && !url.chars().any(|c| c.is_whitespace() || c.is_control());
    let scheme_ok = url.starts_with("https://")
        || url.starts_with("ssh://")
        || (url.starts_with("git@") && url.contains(':') && !url.contains("::"));
    if ok_chars && scheme_ok && !url.contains("::") {
        Ok(())
    } else {
        Err(error(
            "invalid_url",
            "Usa una dirección https://, ssh:// o git@servidor:ruta del repositorio.",
        ))
    }
}

fn validate_folder_name(name: &str) -> Result<()> {
    if name.is_empty()
        || name.len() > 200
        || name.starts_with('-')
        || name.starts_with('.')
        || name.contains('/')
        || name.contains('\\')
        || name.chars().any(|c| c.is_control())
    {
        return Err(error(
            "invalid_path",
            "Nombre de carpeta inválido: sin barras y sin empezar con punto ni guion.",
        ));
    }
    Ok(())
}

/// Clones into `parent/name`; the folder must not exist yet. Returns the new repository path.
pub async fn clone(parent: &Path, url: &str, name: &str) -> Result<String> {
    validate_clone_url(url)?;
    validate_folder_name(name)?;
    let target = parent.join(name);
    if target.exists() {
        return Err(error(
            "path_exists",
            format!("Ya existe una carpeta llamada {name} en ese lugar."),
        ));
    }
    let destination = target.to_string_lossy().to_string();
    git(parent, &["clone", "--", url, &destination]).await.map_err(|failure| {
        // The folder did not exist before: remove whatever a failed or interrupted clone left behind,
        // so retrying does not stop at "already exists".
        let _ = std::fs::remove_dir_all(&target);
        let detail = failure.detail.to_lowercase();
        if detail.contains("host key verification failed") {
            error(
                "clone_host_unknown",
                "Este Mac todavía no confía en ese servidor. Revisa su huella y confía en él antes de clonar por SSH.",
            )
        } else if detail.contains("permission denied (publickey") {
            error(
                "clone_ssh_denied",
                "El servidor no aceptó ninguna clave SSH de este Mac. Registra tu clave pública en tu cuenta de ese servidor y vuelve a intentar.",
            )
        } else if detail.contains("authentication") || detail.contains("permission denied") || detail.contains("could not read username") {
            error(
                "clone_auth",
                "El servidor pidió credenciales. Configura tu llave SSH o el gestor de credenciales de Git y vuelve a intentar.",
            )
        } else if detail.contains("not found") || detail.contains("does not exist") {
            error("clone_not_found", "No se encontró el repositorio o no tienes acceso.")
        } else {
            failure
        }
    })?;
    Ok(destination)
}

/// Default ignores for a new repository on macOS (no project files are committed automatically).
const NEW_REPOSITORY_GITIGNORE: &str = "# macOS\n.DS_Store\n\n# Entornos y secretos\n.env\n.env.*\n!.env.example\n\n# Dependencias y compilación\nnode_modules/\nvendor/\ndist/\nbuild/\ntarget/\n";

/// Creates `parent/name` (or uses it when it exists without a repository) with `main`, a
/// `.gitignore` as the only file of the first commit, and optionally `develop` checked out.
pub async fn init_repository(parent: &Path, name: &str, with_develop: bool) -> Result<String> {
    validate_folder_name(name)?;
    let target = parent.join(name);
    if target.join(".git").exists() {
        return Err(error(
            "path_exists",
            format!("{name} ya es un repositorio Git: ábrelo."),
        ));
    }
    if target.exists() && !target.is_dir() {
        return Err(error(
            "path_exists",
            format!("Ya existe un archivo llamado {name}."),
        ));
    }
    std::fs::create_dir_all(&target).map_err(|_| {
        error(
            "invalid_path",
            "No se pudo crear la carpeta. Revisa que puedas escribir en ese lugar o elige otro.",
        )
    })?;
    git(&target, &["init", "-b", "main"]).await?;
    let ignore = target.join(".gitignore");
    if !ignore.exists() {
        std::fs::write(&ignore, NEW_REPOSITORY_GITIGNORE)
            .map_err(|_| error("invalid_path", "No se pudo escribir .gitignore."))?;
    }
    git(&target, &["add", "--", ".gitignore"]).await?;
    git(&target, &["commit", "-m", "chore: inicia el repositorio"]).await.map_err(|failure| {
        if failure.detail.contains("user.email") || failure.detail.contains("Please tell me who you are") {
            error(
                "git_identity",
                "Git no sabe tu nombre ni tu correo, que van en cada commit. Abre cualquier repositorio, usa Problemas › «Configurar identidad…» con «Todos mis repositorios» y vuelve a intentar.",
            )
        } else {
            failure
        }
    })?;
    if with_develop {
        git(&target, &["switch", "-q", "-c", "develop"]).await?;
    }
    Ok(target.to_string_lossy().to_string())
}

/// Adds `origin` (or reuses it when it already points to `url`) and pushes each existing local
/// branch to the same name with upstream tracking. Never forces.
/// `replace_origin`: the app checked that the existing origin is the same repository (SSH → HTTPS).
pub async fn publish(
    root: &Path,
    url: &str,
    branches: &[String],
    replace_origin: bool,
) -> Result<Vec<String>> {
    validate_clone_url(url)?;
    let current = git(root, &["remote", "get-url", "origin"])
        .await
        .unwrap_or_default();
    if current.trim().is_empty() {
        git(root, &["remote", "add", "origin", url]).await?;
    } else if current.trim() != url && replace_origin {
        git(root, &["remote", "set-url", "origin", url]).await?;
    } else if current.trim() != url {
        return Err(error(
            "remote_exists",
            "Este repositorio ya tiene un remoto origin con otra dirección. Revísalo en Remotos.",
        ));
    }
    let mut pushed: Vec<String> = Vec::new();
    let primary = primary_branch(root).await;
    let protected = main_protected(root).await;
    for branch in branches {
        validate_branch(root, branch).await?;
        if protected && *branch == primary {
            return Err(error(
                "protected_branch",
                format!("{primary} está protegida en este repo: súbela mediante un PR o desactiva la protección."),
            ));
        }
        if git(
            root,
            &[
                "show-ref",
                "--verify",
                "--quiet",
                &format!("refs/heads/{branch}"),
            ],
        )
        .await
        .is_err()
        {
            continue;
        }
        let spec = format!("refs/heads/{branch}:refs/heads/{branch}");
        git(root, &["push", "-u", "origin", &spec])
            .await
            .map_err(access_failure)
            .map_err(|mut failure| {
                if !pushed.is_empty() {
                    failure.detail = format!(
                        "{}\n\nRamas que sí se subieron: {}.",
                        failure.detail,
                        pushed.join(", ")
                    );
                }
                failure
            })?;
        pushed.push(branch.clone());
    }
    Ok(pushed)
}

/// Access problems from push/fetch explained (SSH key not registered, missing HTTPS credentials).
pub fn access_failure(failure: GitError) -> GitError {
    let detail = failure.detail.to_lowercase();
    if detail.contains("permission denied (publickey)") {
        error(
            "ssh_denied",
            "El servidor no reconoce ninguna llave SSH de este Mac. Elige HTTPS (usa tus credenciales de Git o de gh) o agrega tu llave pública en la configuración SSH de tu cuenta.",
        )
    } else if detail.contains("could not read username")
        || detail.contains("authentication failed")
        || detail.contains("terminal prompts disabled")
    {
        error(
            "https_denied",
            "Git no tiene tu usuario ni tu token para este servidor. Guárdalos en el gestor de credenciales de Git (en GitHub, con «gh auth login» en la Terminal) o usa SSH, y vuelve a intentar.",
        )
    } else {
        failure
    }
}
