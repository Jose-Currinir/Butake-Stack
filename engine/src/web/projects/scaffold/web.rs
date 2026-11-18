//! JavaScript frameworks with their official generators, and the basic PHP, Node and static starting points.

use super::*;

pub(super) fn create_javascript(
    store: &Store,
    options: &Options,
    notes: &mut Vec<String>,
) -> Result<Project> {
    let template = template(&options.kind, &options.template)?;
    let (parent, target) = target_of(options)?;
    let (node_bin, runner) = node_runner(store, &format!("create-{}", options.name))?;
    let npx = node_bin.join("npx");
    let name = options.name.as_str();
    match options.kind.as_str() {
        "astro" => runner.run(
            &parent,
            &npx,
            &[
                "--yes",
                "create-astro@latest",
                name,
                "--template",
                template,
                "--install",
                "--no-git",
                "--skip-houston",
                "--yes",
            ],
        )?,
        "emdash" => {
            let platform = if options.platform == "node" {
                "node"
            } else {
                "cloudflare"
            };
            runner.run(
                &parent,
                &npx,
                &[
                    "--yes",
                    "create-emdash@latest",
                    name,
                    "--template",
                    template,
                    "--platform",
                    platform,
                    "--pm",
                    "npm",
                    "--install",
                    "--yes",
                ],
            )?
        }
        "next" => {
            let mut args = vec![
                "--yes",
                "create-next-app@latest",
                name,
                "--ts",
                "--tailwind",
                "--eslint",
                "--app",
                "--use-npm",
                "--disable-git",
                "--no-agent-feedback",
                "--yes",
            ];
            match template {
                "api" => args.push("--api"),
                "empty" => args.push("--empty"),
                _ => {}
            }
            runner.run(&parent, &npx, &args)?
        }
        _ => {
            runner.run(
                &parent,
                &npx,
                &[
                    "--yes",
                    "create-vite@latest",
                    name,
                    "--template",
                    template,
                    "--no-interactive",
                    "--no-immediate",
                ],
            )?;
            runner.run(
                &target,
                &node_bin.join("npm"),
                &["install", "--no-audit", "--no-fund"],
            )?;
        }
    }
    ensure!(target.is_dir(), "scaffold_step_failed");
    if !target.join(".nvmrc").exists()
        && let Some(major) = node_major(&node_bin)
    {
        fs::write(target.join(".nvmrc"), format!("{major}\n"))?;
    }
    if options.git {
        git_init(&runner, &target, notes);
    }
    register(store, &target)
}

/// PHP, Node (node:http, no dependencies) and static sites: a small, working starting point.
pub(super) fn create_basic(
    store: &Store,
    options: &Options,
    notes: &mut Vec<String>,
) -> Result<Project> {
    let (_, target) = target_of(options)?;
    let title = escape_html(&options.name);
    fs::create_dir_all(&target)?;
    let style = "body{font:16px/1.5 -apple-system,system-ui,sans-serif;max-width:40rem;margin:4rem auto;padding:0 1rem;color:#111;background:#fff}@media(prefers-color-scheme:dark){body{color:#eee;background:#111}}";
    match options.kind.as_str() {
        "php" => {
            fs::write(
                target.join("index.php"),
                format!(
                    "<?php\n$title = '{title}';\n?><!doctype html>\n<html lang=\"es\">\n<head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title><?= htmlspecialchars($title) ?></title><style>{style}</style></head>\n<body><h1><?= htmlspecialchars($title) ?></h1><p>PHP <?= PHP_VERSION ?> desde Stack.</p></body>\n</html>\n"
                ),
            )?;
            fs::write(target.join(".gitignore"), "/vendor/\n.env\n")?;
        }
        "node" => {
            let package = serde_json::json!({
                "name": options.name.to_ascii_lowercase(), "private": true, "type": "module",
                "scripts": {"dev": "node --watch server.js", "start": "node server.js"},
            });
            fs::write(
                target.join("package.json"),
                serde_json::to_string_pretty(&package)? + "\n",
            )?;
            fs::write(
                target.join("server.js"),
                format!(
                    "import {{ createServer }} from 'node:http'\n\n// Stack assigns PORT and HOST; the .test address points here.\nconst port = Number(process.env.PORT ?? 3000)\nconst host = process.env.HOST ?? '127.0.0.1'\n\ncreateServer((request, response) => {{\n  response.writeHead(200, {{ 'content-type': 'text/html; charset=utf-8' }})\n  response.end(`<!doctype html><title>{title}</title><style>{style}</style><h1>{title}</h1><p>Node ${{process.version}} desde Stack.</p>`)\n}}).listen(port, host, () => console.log(`http://${{host}}:${{port}}`))\n"
                ),
            )?;
            fs::write(target.join(".gitignore"), "node_modules/\n.env\n")?;
            let (node_bin, _) = node_runner(store, &format!("create-{}", options.name))?;
            if let Some(major) = node_major(&node_bin) {
                fs::write(target.join(".nvmrc"), format!("{major}\n"))?;
            }
        }
        _ => {
            fs::write(
                target.join("index.html"),
                format!(
                    "<!doctype html>\n<html lang=\"es\">\n<head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>{title}</title><style>{style}</style></head>\n<body><h1>{title}</h1><p>Sitio estático servido por Stack.</p></body>\n</html>\n"
                ),
            )?;
        }
    }
    if options.git {
        let runner = Runner {
            extra: vec![],
            path: "/usr/bin:/bin".into(),
            home: Store::home()
                .map(|h| h.to_string_lossy().into_owned())
                .unwrap_or_default(),
            phprc: String::new(),
            log: store
                .directory("logs")?
                .join(format!("create-{}.log", options.name)),
        };
        git_init(&runner, &target, notes);
    }
    register(store, &target)
}

pub(super) fn escape_html(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}
