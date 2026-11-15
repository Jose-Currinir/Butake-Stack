# Capturas del sitio con la ventana de QA y un almacén de demostración inventado (temporal: no toca
# la app instalada, su daemon, el Llavero ni proyectos reales; nada se descarga: las versiones
# «instaladas» son manifiestos y ejecutables vacíos dentro del almacén temporal).
# Requiere la compilación de depuración:
#   (cd engine && cargo build) && xcrun swift build --disable-sandbox --package-path native
# Uso, desde la raíz del repo:  python3 site/scripts/capturas.py [nombres...]
# Escribe <nombre>.png (claro) y <nombre>-oscuro.png en docs/presentacion/.
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time

root = pathlib.Path.cwd()
output = root / "docs/presentacion"
engine = root / "engine/target/debug/butake-stack"
app = root / "native/.build/debug/ButakeStack"
SIZE = os.environ.get("CAPTURAS_SIZE", "1280x780")

PROJECTS = [
    # id, nombre, tipo, versiones, carpeta pública, rama, servicios, procesos
    ("tienda", "Tienda", "laravel", {"php": "8.4", "node": "22"}, "public", "develop", ["mysql", "redis"],
     [("vite", "npm", ["run", "dev"]), ("cola", "php", ["artisan", "queue:work"]), ("reverb", "php", ["artisan", "reverb:start"])]),
    ("blog", "Blog", "astro", {"node": "22"}, ".", "main", [], []),
    ("api", "API", "fastapi", {"python": "3.13"}, ".", "main", ["mysql"], []),
    ("panel", "Panel", "django", {"python": "3.13"}, ".", "feature/reportes", ["mysql", "redis"], []),
    ("app-salud", "App Salud", "kmp", {}, ".", "main", [], []),
]

# Herramientas «instaladas» (carpeta = versión exacta) y líneas de PHP.
TOOLS = {"node": ["24.22.3", "22.23.5"], "mysql": ["8.4.7"], "redis": ["8.2.3"],
         "valkey": ["8.1.4"], "meilisearch": ["1.24.0"], "caddy": ["2.10.2"]}
PHP = {"8.4": "8.4.27", "8.3": "8.3.36"}
EXECUTABLES = {"node": ["bin/node", "bin/npm", "bin/npx"], "mysql": ["bin/mysqld", "bin/mysql", "bin/mysqldump"],
               "redis": ["bin/redis-server", "bin/redis-cli"], "valkey": ["bin/valkey-server", "bin/valkey-cli"],
               "postgres": ["bin/postgres", "bin/initdb", "bin/psql", "bin/pg_dump", "bin/pg_isready"],
               "meilisearch": ["bin/meilisearch"], "caddy": ["caddy"]}
RUNNING = ["stack.redis", "stack.valkey", "stack.meilisearch",
           "tienda.vite", "tienda.cola", "tienda.reverb"]

SCENES = {
    "inicio": {"BUTAKE_QA_ROUTE": "home"},
    "sitio": {"BUTAKE_QA_ROUTE": "site:tienda", "BUTAKE_QA_PROJECT_TAB": "summary"},
    "bases-de-datos": {"BUTAKE_QA_ROUTE": "service:database"},
    "cache": {"BUTAKE_QA_ROUTE": "service:cache"},
    "lenguajes": {"BUTAKE_QA_ROUTE": "language:php"},
    "node": {"BUTAKE_QA_ROUTE": "language:node"},
    "nuevo-proyecto": {"BUTAKE_QA_NEW": "laravel"},
    "panel": {"BUTAKE_QA_PANEL": "all"},
    "preparar": {"BUTAKE_QA_SETUP": "2"},
}


def git(path, *args):
    env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1",
               GIT_AUTHOR_NAME="Demo", GIT_AUTHOR_EMAIL="demo@ejemplo.cl",
               GIT_COMMITTER_NAME="Demo", GIT_COMMITTER_EMAIL="demo@ejemplo.cl")
    subprocess.run(["git", *args], cwd=path, env=env, check=True, capture_output=True)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def touch_executable(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\nexit 0\n")
    path.chmod(0o755)


# Fuera de /tmp (enlace a /private/tmp): la app abrevia la carpeta del proyecto como ~/Stack/Projects/….
with tempfile.TemporaryDirectory(prefix="stack-sitio-", dir=pathlib.Path.home() / "Library/Caches") as directory:
    qa = pathlib.Path(directory).resolve()
    store = qa / "store"
    home = qa / "home"
    (store / "projects").mkdir(parents=True)
    home.mkdir()
    for tool, versions in TOOLS.items():
        for version in versions:
            folder = store / "runtimes" / tool / version
            for exe in EXECUTABLES[tool]:
                touch_executable(folder / exe)
            (folder / "butake-manifest.json").write_text(json.dumps({
                "tool": tool, "version": version, "url": f"https://ejemplo.invalid/{tool}-{version}.tar.gz",
                "checksum_url": "", "sha256": "0" * 64, "installed_at": 1763000000}))
    for series, version in PHP.items():
        folder = store / "runtimes/php" / series
        files = ["bin/php", "bin/php-fpm", "composer.phar", "cacert.pem", "xdebug.so"]
        for name in files:
            touch_executable(folder / name)
        (folder / "manifest.json").write_text(json.dumps({
            "version": version, "series": series, "architecture": "arm64", "minimum_macos": "15.0",
            "spc_version": "2.7.0", "built_at": "2026-11-10T12:00:00Z",
            "extensions": ["bcmath", "curl", "gd", "intl", "mbstring", "opcache", "pdo_mysql", "pdo_pgsql", "redis", "zip"],
            "missing_extensions": [], "sha256": {name: sha(folder / name) for name in files}}))
    (store / "stack.json").write_text(json.dumps({
        "tld": ["test"], "ports": {"http": 80, "https": 443, "dns": 53, "mysql": 3306, "redis": 6379},
        "versions": {"php": "8.4", "node": "22"},
        "engines": {name: {"enabled": True, "version": ""} for name in ["mysql", "redis", "valkey", "meilisearch"]}}))
    for pid, name, kind, runtime, docroot, branch, services, processes in PROJECTS:
        path = home / "Stack" / "Projects" / pid
        (path / docroot).mkdir(parents=True, exist_ok=True)
        (path / docroot / "index.html").write_text(f"<h1>{name}</h1>")
        git(path, "init", "-q", "-b", branch)
        git(path, "add", ".")
        git(path, "commit", "-q", "-m", "Inicio")
        if pid == "tienda":
            (path / "package.json").write_text('{"name": "tienda", "scripts": {"dev": "vite"}}')
            (path / "artisan").write_text("<?php\n")
            git(path, "add", ".")
            git(path, "commit", "-q", "-m", "Laravel")
            (path / "nuevo.txt").write_text("cambio pendiente\n")
        (store / "projects" / f"{pid}.json").write_text(json.dumps({
            "id": pid, "name": name, "path": str(path), "domains": [f"{pid}.test"],
            "https": True, "kind": kind, "runtime": runtime, "docroot": docroot,
            "services": services, "databases": [],
            "processes": [{"name": n, "program": p, "args": a, "autostart": True} for n, p, a in processes],
            "enabled": True,
        }))
    env = dict(os.environ, BUTAKE_STACK_HOME=str(store), BUTAKE_STACK_ENGINE=str(engine),
               BUTAKE_DEVTOOLS_HOME=str(home), BUTAKE_QA_WINDOW="1", BUTAKE_QA_STACK="running",
               BUTAKE_QA_STACK_PROCESSES=",".join(RUNNING), BUTAKE_QA_SITES_ONLINE="1",
               BUTAKE_QA_WINDOW_SIZE=SIZE, BUTAKE_QA_SNAPSHOT_DELAY="5",
               CFFIXED_USER_HOME=str(home), TMPDIR=str(qa) + "/")
    subprocess.run([engine], env=env, input=json.dumps({"method": "saveSiteGroups", "groups": [
        {"id": "clientes", "name": "Clientes", "sites": ["tienda", "panel"]}]}), capture_output=True, text=True)
    names = sys.argv[1:] or list(SCENES)
    for name in names:
        for theme, suffix in [("light", ""), ("dark", "-oscuro")]:
            target = output / f"{name}{suffix}.png"
            target.unlink(missing_ok=True)
            for key in ["NSSplitView Subview Frames main, SidebarNavigationSplitView", "sidebar.closedSections", "sidebar.collapsedGroups"]:
                subprocess.run(["defaults", "delete", "ButakeStack", key], capture_output=True)
            params = SCENES[name]
            log = (qa / f"{name}{suffix}.log").open("w")
            process = subprocess.Popen([app, "-textScale", "1.0", "-themeMode", theme, "-autoUpdateCheck", "NO", "-themeFamily", "butake"],
                                       env=dict(env, BUTAKE_QA_SNAPSHOT=str(target), **params), stdout=log, stderr=log)
            until = time.monotonic() + float(params.get("BUTAKE_QA_SNAPSHOT_DELAY", "5")) + 10
            while not target.exists() and time.monotonic() < until:
                time.sleep(.15)
            time.sleep(.4)
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=5)
            print(name, theme, "OK" if target.exists() else "FALTA", flush=True)
