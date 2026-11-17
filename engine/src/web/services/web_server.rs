//! Stack-level services: one php-fpm per PHP series in use and Caddy for the sites. Files are
//! generated from the model on every reload and never edited by hand.
use crate::core::fsutil::write_private;
use crate::{
    core::model::{Project, ProjectKind, StackConfig},
    core::store::Store,
    runtimes::{languages::php, utilities::catalog},
};
use anyhow::{ensure, Result};
use std::{collections::BTreeSet, fs};

pub fn php_series(project: &Project, config: &StackConfig) -> Option<String> {
    matches!(project.kind, ProjectKind::Laravel | ProjectKind::Php).then(|| {
        project
            .runtime
            .get("php")
            .or_else(|| config.versions.get("php"))
            .cloned()
            .unwrap_or_else(|| "8.2".into())
    })
}

pub fn series_in_use(projects: &[Project], config: &StackConfig) -> BTreeSet<String> {
    projects
        .iter()
        .filter_map(|p| php_series(p, config))
        .collect()
}

pub fn fpm_socket(store: &Store, series: &str) -> Result<std::path::PathBuf> {
    Ok(store.directory("run")?.join(format!("php-{series}.sock")))
}

/// Writes php.ini and php-fpm.conf for a verified runtime; returns (fpm.conf, php.ini).
pub fn fpm_config(store: &Store, series: &str) -> Result<(std::path::PathBuf, std::path::PathBuf)> {
    let ini = php::generate_ini(store, series)?;
    let socket = fpm_socket(store, series)?;
    let text = socket.to_string_lossy();
    ensure!(
        !text.chars().any(|c| c.is_control() || c == ';' || c == '"'),
        "invalid_fpm_path"
    );
    let conf = format!(
        "[global]\ndaemonize = no\nerror_log = /dev/stderr\nlog_level = notice\n\n\
         [butake]\nlisten = {text}\nlisten.mode = 0600\npm = ondemand\npm.max_children = 10\n\
         pm.process_idle_timeout = 30s\ncatch_workers_output = yes\ndecorate_workers_output = no\n"
    );
    let path = ini.parent().unwrap().join("php-fpm.conf");
    write_private(&path, &conf)?;
    Ok((path, ini))
}

fn quoted(value: &str) -> Result<String> {
    ensure!(
        !value
            .chars()
            .any(|c| c.is_control() || matches!(c, '"' | '\\' | '{' | '}' | '`')),
        "invalid_caddy_value"
    );
    Ok(format!("\"{value}\""))
}

/// Answers 404 to any path with a segment that starts with a dot (`.env`, `.git/config`, `..`),
/// before PHP or the file server see it, so a folder served from the project root never publishes
/// them. Only `/.well-known/` stays reachable, and only through segments that do not start with a
/// dot themselves (`/.well-known/../.env` is refused). Caddy's regular expressions have no
/// look-ahead, hence the second, negated, expression.
const HIDDEN_FILES: &str = "\t@hidden {\n\t\tpath_regexp hidden (^|/)\\.\n\t\tnot path_regexp wellknown ^/\\.well-known/([^/.][^/]*/?)*$\n\t}\n\trespond @hidden 404\n";

/// Whether the folder a site serves can go into the Caddyfile (`quoted` refuses `{ } \\ " \``).
pub fn serves_safely(project: &Project) -> bool {
    quoted(&project.path.join(&project.docroot).to_string_lossy()).is_ok()
}

enum Backend {
    Php(std::path::PathBuf),
    /// Port, and whether the Host header must be rewritten (Vite's allowed hosts).
    Proxy(u16, bool),
    Files,
}

/// HTML entities for text placed in the off page.
fn html(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
        // Caddy substitutes `{env.X}` and `{file.<path>}` inside the heredoc body when it runs.
        .replace('{', "&#123;")
        .replace('}', "&#125;")
}

/// Page served while a site is off: its name and address, light and dark, and a link that opens
/// the site's page in the app (it never turns the site on: no web page can do that).
/// One line, so it fits a Caddyfile heredoc without indentation rules.
pub fn off_page(project: &Project) -> String {
    let name = html(&project.name);
    let domain = html(project.domains.first().map(String::as_str).unwrap_or(""));
    let id = html(&project.id);
    format!(concat!(
        "<!doctype html><html lang=es><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>",
        "<title>{name} está apagado</title><style>",
        ":root{{--bg:#f5f5f7;--card:#fff;--text:#1d1d1f;--muted:#6e6e73;--line:#e5e5ea;--accent:#0b8147}}",
        "@media (prefers-color-scheme:dark){{:root{{--bg:#111;--card:#1c1c1e;--text:#f5f5f7;--muted:#98989d;--line:#2c2c2e;--accent:#19d79f}}}}",
        "*{{box-sizing:border-box}}body{{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px;background:var(--bg);color:var(--text);font:16px/1.5 -apple-system,BlinkMacSystemFont,'Inter',sans-serif}}",
        ".card{{max-width:440px;width:100%;background:var(--card);border:1px solid var(--line);border-radius:20px;padding:32px;box-shadow:0 20px 50px #0000001a}}",
        ".state{{display:inline-flex;align-items:center;gap:8px;font-size:13px;font-weight:600;color:var(--muted);padding:4px 10px;border:1px solid var(--line);border-radius:999px}}",
        ".dot{{width:8px;height:8px;border-radius:50%;background:var(--muted)}}h1{{font-size:26px;line-height:1.2;margin:18px 0 6px}}",
        "code{{font:14px ui-monospace,SFMono-Regular,monospace;color:var(--muted)}}p{{color:var(--muted);margin:16px 0 24px}}",
        "a.button{{display:inline-block;background:var(--accent);color:#fff;text-decoration:none;font-weight:600;padding:11px 18px;border-radius:12px}}",
        "@media (prefers-color-scheme:dark){{a.button{{color:#0b2b20}}}}footer{{margin-top:24px;font-size:12px;color:var(--muted)}}",
        "</style><main class=card><span class=state><span class=dot></span>Apagado</span><h1>{name}</h1><code>{domain}</code>",
        "<p>Este sitio está registrado en Stack, pero no se está sirviendo. Enciéndelo desde la app o desde la barra de menús.</p>",
        "<a class=button href='butakestack://site/{id}'>Abrir en Stack</a><footer>Stack, de Butake · desarrollo local</footer></main></html>"
    ), name = name, domain = domain, id = id)
}

/// Caddyfile for every PHP site. `skip_install_trust`: Caddy never touches the keychain itself;
/// the app trusts its root with the user's confirmation (`system::trust_authority`). Sockets come from inherited descriptors: `fd/3` for HTTP and
/// `fd/4` for HTTPS, whether launchd or the daemon opened them.
pub fn caddyfile(
    store: &Store,
    projects: &[Project],
    config: &StackConfig,
    http3: bool,
) -> Result<String> {
    let data = store.directory("data")?.join("caddy");
    fs::create_dir_all(&data)?;
    let mut out = format!(
        "{{\n\tadmin off\n\tpersist_config off\n\tauto_https disable_redirects\n\tskip_install_trust\n\
         \tstorage file_system {}\n}}\n\n",
        quoted(&data.to_string_lossy())?
    );
    for project in projects {
        let series = php_series(project, config);
        // Served: PHP sites through php-fpm, proxied sites (Astro, EmDash, Next, KMP…) through
        // their own server, static sites as files.
        let backend = match (&series, project.upstream) {
            (Some(series), _) => Backend::Php(fpm_socket(store, series)?),
            (None, Some(port)) if project.kind.proxied() => Backend::Proxy(
                port,
                matches!(
                    project.kind,
                    crate::core::model::ProjectKind::Astro
                        | crate::core::model::ProjectKind::Django
                ),
            ),
            (None, _) if project.kind == crate::core::model::ProjectKind::Static => Backend::Files,
            _ => continue,
        };
        let root = project.path.join(&project.docroot);
        // A folder Caddy cannot be told about safely is left out, not allowed to void the file of
        // every other site; the project's page says why (`unsafe_web_path`).
        if project.enabled && !serves_safely(project) && !matches!(backend, Backend::Proxy(..)) {
            continue;
        }
        let mut schemes = vec![("http", "fd/3")];
        if project.https {
            schemes.push(("https", "fd/4"));
        }
        for (scheme, bind) in schemes {
            let hosts: Vec<_> = project
                .domains
                .iter()
                .map(|d| format!("{scheme}://{d}"))
                .collect();
            out.push_str(&format!("{} {{\n", hosts.join(", ")));
            if !project.enabled {
                // Off sites answer at once instead of leaving the browser waiting. Protocols are
                // explicit: a TCP descriptor cannot carry HTTP/3, which Caddy would otherwise try.
                let protocols = if scheme == "https" { "h1 h2" } else { "h1" };
                out.push_str(&format!(
                    "\tbind {bind} {{\n\t\tprotocols {protocols}\n\t}}\n"
                ));
                if scheme == "https" {
                    out.push_str("\ttls internal\n");
                }
                // A page of its own (never cached, so turning the site on shows the site at once).
                out.push_str("\theader Content-Type \"text/html; charset=utf-8\"\n\theader Cache-Control \"no-store\"\n");
                out.push_str(&format!(
                    "\trespond <<BUTAKE_OFF\n\t{}\n\tBUTAKE_OFF 503\n}}\n\n",
                    off_page(project)
                ));
                continue;
            }
            if scheme == "https" {
                // TLS 1.3 by default; HTTP/1.1 and HTTP/2 over TCP, HTTP/3 over QUIC.
                out.push_str(&format!("\tbind {bind} {{\n\t\tprotocols h1 h2\n\t}}\n"));
                if http3 {
                    out.push_str("\tbind fdgram/5 {\n\t\tprotocols h3\n\t}\n");
                }
                out.push_str("\ttls internal\n");
            } else {
                out.push_str(&format!("\tbind {bind} {{\n\t\tprotocols h1\n\t}}\n"));
            }
            match &backend {
                Backend::Php(socket) => out.push_str(&format!(
                    "\troot * {}\n\tencode zstd gzip\n{HIDDEN_FILES}\tphp_fastcgi {}\n\tfile_server\n}}\n\n",
                    quoted(&root.to_string_lossy())?,
                    quoted(&format!("unix/{}", socket.to_string_lossy()))?
                )),
                // Vite (Astro) only answers its own host unless configured otherwise: the dev server
                // sees localhost; WebSockets (HMR) pass through.
                Backend::Proxy(port, rewrite_host) => out.push_str(&format!(
                    "\treverse_proxy 127.0.0.1:{port}{}\n}}\n\n",
                    if *rewrite_host {
                        format!(" {{\n\t\theader_up Host localhost:{port}\n\t}}")
                    } else {
                        String::new()
                    }
                )),
                Backend::Files => out.push_str(&format!(
                    "\troot * {}\n\tencode zstd gzip\n{HIDDEN_FILES}\tfile_server\n}}\n\n",
                    quoted(&root.to_string_lossy())?
                )),
            }
        }
    }
    Ok(out)
}

pub fn caddy_executable(store: &Store, config: &StackConfig) -> Option<std::path::PathBuf> {
    let wanted = config
        .versions
        .get("caddy")
        .map(String::as_str)
        .unwrap_or("");
    catalog::resolve(store, "caddy", wanted).map(|dir| dir.join("caddy"))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn caddyfile_quotes_paths_and_rejects_injection() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        let site = temp.path().join("My Site");
        fs::create_dir_all(site.join("public")).unwrap();
        let mut project: Project = serde_json::from_value(serde_json::json!({
            "id":"demo","name":"Demo","path":site,"domains":["demo.test"],"https":true,
            "kind":"laravel","runtime":{"php":"8.2"},"docroot":"public","services":[],
            "databases":[],"processes":[],"enabled":true}))
        .unwrap();
        let config = StackConfig::default();
        project.validate(&config).unwrap();
        let file = caddyfile(&store, &[project.clone()], &config, true).unwrap();
        assert!(file.contains("http://demo.test {\n\tbind fd/3 {\n\t\tprotocols h1\n"));
        assert!(file.contains("https://demo.test {\n\tbind fd/4 {\n\t\tprotocols h1 h2\n"));
        assert!(file.contains("\tbind fdgram/5 {\n\t\tprotocols h3\n\t}\n\ttls internal"));
        assert!(file.contains("My Site/public\""));
        // An off site never asks for HTTP/3 on a TCP descriptor.
        let mut off = project.clone();
        off.enabled = false;
        let file_off = caddyfile(&store, &[off], &config, true).unwrap();
        assert!(file_off.contains(
            "https://demo.test {\n\tbind fd/4 {\n\t\tprotocols h1 h2\n\t}\n\ttls internal"
        ));
        assert!(!file_off.contains("fdgram"));
        assert!(
            file_off.contains("respond <<BUTAKE_OFF")
                && file_off.contains("BUTAKE_OFF 503")
                && file_off.contains("no-store")
        );
        let mut evil_name = project.clone();
        evil_name.name = "<script>x</script>".into();
        evil_name.id = "otro".into();
        evil_name.domains = vec!["otro.test".into()];
        evil_name.enabled = false;
        assert!(
            off_page(&evil_name).contains("&lt;script&gt;") && !off_page(&evil_name).contains('\n')
        );
        // Caddy placeholders in a name never reach the page as such (R-04).
        let mut braces = evil_name.clone();
        braces.name = "{env.HOME}{file./etc/hosts}".into();
        let page = off_page(&braces);
        assert!(!page.contains("{env.") && !page.contains("{file.") && page.contains("&#123;env."));
        // With a real Caddy available (CADDY_BIN), the generated file must adapt cleanly.
        if let Some(caddy) = std::env::var_os("CADDY_BIN") {
            let mut astro = project.clone();
            astro.id = "astro".into();
            astro.domains = vec!["astro.test".into()];
            astro.kind = crate::core::model::ProjectKind::Astro;
            astro.runtime.clear();
            astro.upstream = Some(4401);
            let both = caddyfile(
                &store,
                &[evil_name.clone(), project.clone(), astro],
                &config,
                true,
            )
            .unwrap();
            assert!(
                both.contains("reverse_proxy 127.0.0.1:4401")
                    && both.contains("header_up Host localhost:4401")
            );
            let path = temp.path().join("Caddyfile");
            fs::write(&path, both).unwrap();
            let out = std::process::Command::new(caddy)
                .args(["adapt", "--adapter", "caddyfile", "--config"])
                .arg(&path)
                .output()
                .unwrap();
            assert!(
                out.status.success(),
                "{}",
                String::from_utf8_lossy(&out.stderr)
            );
        }
        assert!(file.contains("php_fastcgi \"unix/"));
        // Dotfiles answer 404 before PHP or the file server (R-03), except `/.well-known/`.
        let hidden = file.find("respond @hidden 404").unwrap();
        assert!(hidden < file.find("php_fastcgi").unwrap());
        assert!(file.contains("path_regexp hidden (^|/)\\.") && file.contains("^/\\.well-known/"));
        let mut files = project.clone();
        files.id = "libro".into();
        files.domains = vec!["libro.test".into()];
        files.kind = crate::core::model::ProjectKind::Static;
        files.runtime.clear();
        files.docroot = ".".into();
        let static_file = caddyfile(&store, &[files], &config, true).unwrap();
        assert!(
            static_file.find("respond @hidden 404").unwrap()
                < static_file.find("file_server").unwrap()
        );
        let evil = temp.path().join("x}\nimport");
        fs::create_dir_all(&evil).unwrap();
        project.path = evil;
        project.docroot = ".".into();
        // The site with that folder is left out; the others still get their file (R-59).
        let mut healthy = project.clone();
        healthy.path = site.clone();
        healthy.id = "sano".into();
        healthy.domains = vec!["sano.test".into()];
        healthy.docroot = "public".into();
        assert!(!serves_safely(&project) && serves_safely(&healthy));
        let mixed = caddyfile(&store, &[project, healthy], &config, true).unwrap();
        assert!(mixed.contains("sano.test") && !mixed.contains("demo.test"));
    }
}
