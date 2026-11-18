//! Remotes: clone and create repositories, publish local branches (never forced), explain access
//! failures and build the link to a new pull request. URLs leave the engine without credentials.
use super::actions::validate_branch;
use super::protection::{main_protected, primary_branch};
use super::runner::{GitError, Result, error, git};
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

/// Whether the address carries a user and password or token that Git would write into
/// `.git/config`: any user in an `https://` address (a token is often pasted as the user) and a
/// password in an `ssh://` one. A plain `ssh://git@host/…` or `git@host:path` is fine.
pub fn embeds_credentials(url: &str) -> bool {
    let Some((scheme, rest)) = url.split_once("://") else {
        return false;
    };
    let authority = &rest[..rest.find('/').unwrap_or(rest.len())];
    let Some((user, _)) = authority.rsplit_once('@') else {
        return false;
    };
    let web = scheme.eq_ignore_ascii_case("https") || scheme.eq_ignore_ascii_case("http");
    user.contains(':') || (web && looks_like_token(user))
}

/// A user part that is really a secret: the providers' token prefixes, or anything long enough to
/// be one. A plain name (`ana@bitbucket.org`, as Bitbucket's own clone address has) is not.
fn looks_like_token(user: &str) -> bool {
    const PREFIXES: &[&str] = &[
        "ghp_",
        "gho_",
        "ghu_",
        "ghs_",
        "ghr_",
        "github_pat_",
        "glpat-",
        "ATBB",
        "ATATT",
        "ATCTT",
    ];
    PREFIXES.iter().any(|p| user.starts_with(p)) || user.len() >= 32
}

/// The address Stack stores and gives to Git: an https address without its user (the connected
/// account, or the user's own credential helper, answers for it), anything else as written.
pub fn stored_address(url: &str) -> String {
    let web = url.starts_with("https://") || url.starts_with("http://");
    if web {
        without_credentials(url)
    } else {
        url.to_string()
    }
}

/// The addresses of every remote of the repository (fetch and push), as configured.
pub async fn urls(root: &Path) -> Vec<String> {
    git(
        root,
        &["config", "--get-regexp", r"^remote\..*\.(push)?url$"],
    )
    .await
    .unwrap_or_default()
    .lines()
    .filter_map(|line| line.split_once(' ').map(|(_, url)| url.trim().to_string()))
    .collect()
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
        if embeds_credentials(url) {
            return Err(error(
                "invalid_url",
                "Quita el usuario y la clave de la dirección: Stack usa tu cuenta conectada.",
            ));
        }
        Ok(())
    } else {
        Err(error(
            "invalid_url",
            "Usa una dirección https://, ssh:// o git@servidor:ruta del repositorio.",
        ))
    }
}

/// The address of a remote added by hand: what `validate_clone_url` accepts, or the absolute path
/// of an existing folder on this Mac (a backup remote). `file://`, `http://`, `ext::` and the
/// other transports are not remotes Stack adds.
pub fn validate_remote_url(url: &str) -> Result<()> {
    if url.starts_with('/') {
        let plain = url.len() < 2_048
            && !url.contains("::")
            && !url.chars().any(|c| c.is_whitespace() || c.is_control());
        if plain && std::path::Path::new(url).is_dir() {
            return Ok(());
        }
        return Err(error(
            "invalid_url",
            "La carpeta del remoto no existe o no se puede usar.",
        ));
    }
    validate_clone_url(url)
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
    let url = &stored_address(url);
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
        } else if let Some(rejected) = token_failure(&detail) {
            rejected
        } else if detail.contains("authentication") || detail.contains("permission denied") || detail.contains("could not read username") {
            error(
                "clone_auth",
                "El servidor pidió credenciales. Configura tu llave SSH o el gestor de credenciales de Git y vuelve a intentar.",
            )
        } else if (detail.contains("repository") && detail.contains("not found")) || detail.contains("does not exist") {
            error("clone_not_found", "No se encontró el repositorio o no tienes acceso.")
        } else if is_offline(&detail) {
            error(
                "clone_offline",
                "Sin conexión con el servidor. Revisa tu conexión a internet y vuelve a intentar.",
            )
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
    let url = &stored_address(url);
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
                format!(
                    "{primary} está protegida en este repo: súbela mediante un PR o desactiva la protección."
                ),
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

/// The server could not be reached at all (DNS, connection or time out).
fn is_offline(detail: &str) -> bool {
    [
        "could not resolve host",
        "timed out",
        "could not connect",
        "connection refused",
        "network is unreachable",
    ]
    .iter()
    .any(|phrase| detail.contains(phrase))
}

/// A refusal of the token of the connected account (only when the transfer carried one): rejected
/// (expired, revoked or wrong) or valid but without permission for that repository.
fn token_failure(detail: &str) -> Option<GitError> {
    if !super::credentials::active() {
        return None;
    }
    if detail.contains("returned error: 403")
        || detail.contains("permission to")
        || detail.contains("denied to")
        || detail.contains("write access to repository not granted")
    {
        Some(error(
            "token_forbidden",
            "Tu cuenta conectada no tiene permiso de escritura en este repositorio. Revisa los permisos de su token en Ajustes › Cuentas.",
        ))
    } else if detail.contains("authentication failed")
        || detail.contains("invalid username or token")
        || detail.contains("returned error: 401")
        || detail.contains("invalid credentials")
    {
        Some(error(
            "token_rejected",
            "El servidor no aceptó el token de tu cuenta conectada: puede haber vencido o haberse revocado. Conéctala de nuevo en Ajustes › Cuentas.",
        ))
    } else {
        None
    }
}

/// Access problems from push/fetch explained (SSH key not registered, missing HTTPS credentials,
/// a token the server refuses).
pub fn access_failure(failure: GitError) -> GitError {
    let detail = failure.detail.to_lowercase();
    if detail.contains("permission denied (publickey)") {
        error(
            "ssh_denied",
            "El servidor no reconoce ninguna llave SSH de este Mac. Elige HTTPS (usa tus credenciales de Git o de gh) o agrega tu llave pública en la configuración SSH de tu cuenta.",
        )
    } else if let Some(rejected) = token_failure(&detail) {
        rejected
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
