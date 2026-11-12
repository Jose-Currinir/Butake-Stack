"""Explicit, isolated PHP build. No shell strings, system installs or project reads."""
import argparse
import configparser
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import shlex
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent
PINS = json.loads((ROOT / "VERSIONS").read_text())
EXTENSIONS = (ROOT / "extensions.txt").read_text().strip().split(",")
TOOLS = ("curl", "make", "bison", "re2c", "flex", "git", "autoconf", "automake", "tar", "libtool", "unzip", "xz", "gzip", "bzip2", "cmake", "glibtoolize")


def private_directory(root, relative):
    directory = root
    for part in Path(relative).parts:
        if part in ("..", "/"):
            raise RuntimeError("unsafe_managed_path")
        directory = directory / part
        if directory.is_symlink():
            raise RuntimeError("unsafe_managed_path")
        directory.mkdir(mode=0o700, exist_ok=True)
    return directory


def atomic_json(path, value):
    descriptor, temporary = tempfile.mkstemp(prefix=".write-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as output:
            json.dump(value, output, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def download(pin, path, ledger, environment):
    subprocess.run(["/usr/bin/curl", "--disable", "--fail", "--location", "--max-time", "300",
                    "--proto", "=https", "--proto-redir", "=https", "--tlsv1.2",
                    "-H", "Accept: application/octet-stream", "--output", str(path), pin["url"]], check=True, env=environment)
    actual = digest(path)
    if actual != pin["sha256"]:
        path.unlink()
        raise RuntimeError("download_hash_mismatch")
    ledger.append({"url": pin["url"], "sha256": actual, "bytes": path.stat().st_size})


def extract(archive, destination):
    destination.mkdir(parents=True, exist_ok=True)
    root = destination.resolve()
    with tarfile.open(archive) as source:
        for member in source.getmembers():
            target = (root / member.name).resolve()
            if root != target and root not in target.parents:
                raise RuntimeError("unsafe_archive_path")
            if not member.isfile() and not member.isdir():
                raise RuntimeError("unsafe_archive_entry")
        source.extractall(root)


def preflight(environment):
    missing = [tool for tool in TOOLS if not shutil.which(tool, path=environment["PATH"])]
    if missing:
        raise RuntimeError("missing_build_tools: " + ", ".join(missing))
    bison = shutil.which("bison", path=environment["PATH"])
    output = subprocess.check_output([bison, "--version"], env=environment, text=True)
    if not re.search(r"Bison\) [3-9]\.", output):
        raise RuntimeError("bison_3_required")


def source_ledger(source):
    lock_path = source / "downloads/.lock.json"
    if not lock_path.exists():
        return []
    urls = {}
    log_path = source / "log/spc.output.log"
    if log_path.exists():
        for line in log_path.read_text(errors="replace").splitlines():
            if "[PASSTHRU]" not in line:
                continue
            try:
                command = shlex.split(line.split("[PASSTHRU]", 1)[1])
                remote = next((part for part in command if part.startswith("https://")), None)
                if remote and "-o" in command:
                    urls[Path(command[command.index("-o") + 1]).name] = remote
                elif remote and "clone" in command:
                    urls[Path(command[-1]).name] = remote
            except ValueError:
                continue
    records = []
    for key, item in json.loads(lock_path.read_text()).items():
        download_root = (source / "downloads").resolve()
        path = (download_root / item.get("filename", key)).resolve()
        if download_root not in path.parents:
            raise RuntimeError("unsafe_source_path")
        remote = urls.get(path.name)
        if key == "pkg-config-aarch64-macos":
            remote = PINS["pkgconfig"]["url"]
        record = {"source": key, "filename": path.name, "url": remote, "spc_lock": item}
        if path.is_file():
            record["sha256"] = digest(path)
            record["bytes"] = path.stat().st_size
        elif (path / ".git").exists():
            record["git_commit"] = subprocess.check_output(["/usr/bin/git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()
            pending = [path]
            submodules = []
            while pending:
                parent = pending.pop()
                if not (parent / ".gitmodules").is_file():
                    continue
                modules = configparser.ConfigParser()
                modules.read(parent / ".gitmodules")
                for section in modules.sections():
                    child = (parent / modules[section]["path"]).resolve()
                    if parent.resolve() not in child.parents or not (child / ".git").exists():
                        continue
                    commit = subprocess.check_output(["/usr/bin/git", "-C", str(child), "rev-parse", "HEAD"], text=True).strip()
                    submodules.append({"path": str(child.relative_to(path.resolve())), "url": modules[section]["url"], "git_commit": commit})
                    pending.append(child)
            if submodules:
                record["submodules"] = submodules
        records.append(record)
    return records


def build(minor, home, build_root):
    build_root.mkdir(parents=True, exist_ok=True)
    home.mkdir(parents=True, exist_ok=True)
    home = home.resolve()
    log_directory = private_directory(home, "logs")
    work = Path(tempfile.mkdtemp(prefix=minor + "-", dir=build_root)).resolve()
    log_path = log_directory / ("php-build-" + minor + ".log")
    ledger = []
    environment = {"HOME": str(work / "home"), "PATH": "/opt/homebrew/opt/bison/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin",
                   "LANG": "C", "MACOSX_DEPLOYMENT_TARGET": "14.0", "SPC_CONCURRENCY": "4", "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1"}
    # static-php-cli asks GitHub's API for many sources; without a token the 60 calls/hour limit
    # breaks the build. The token only reaches spc's own requests; logs are scrubbed by the caller.
    if os.environ.get("GITHUB_TOKEN"):
        environment["GITHUB_TOKEN"] = os.environ["GITHUB_TOKEN"]
    (work / "home").mkdir()
    try:
        preflight(environment)
        engine_value = os.environ.get("BUTAKE_STACK_ENGINE")
        if engine_value:
            engine = Path(engine_value).resolve(strict=True)
        else:
            engine = ROOT.parents[1] / "engine/target/release/butake-stack"
            if not engine.is_file():
                engine = ROOT.parents[1] / "engine/target/debug/butake-stack"
            engine = engine.resolve(strict=True)
        for key in ("spc", "source", "pkgconfig", "composer", "cacert"):
            download(PINS[key], work / (key + ".download"), ledger, environment)
        extract(work / "source.download", work / "source")
        source = work / "source/static-php-cli-2.8.5"
        extract(work / "spc.download", source)
        # The hosted archive nests everything under buildroot/; spc looks for pkgroot/<arch>/bin/pkg-config.
        extract(work / "pkgconfig.download", work / "pkgconfig")
        pkgroot = source / "pkgroot/aarch64-darwin"
        pkgroot.mkdir(parents=True, exist_ok=True)
        for item in (work / "pkgconfig/buildroot").iterdir():
            shutil.move(str(item), str(pkgroot / item.name))
        spc = source / "spc"
        spc.chmod(0o700)
        # 'never' prevents SPC's noninteractive default from accepting repairs.
        # Own preflight is necessary: SPC 2.8.5 does not fail all 'never' checks.
        log_descriptor = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(log_descriptor, "w") as log:
            def run(arguments):
                print(json.dumps({"event": "build.command", "arguments": arguments}), flush=True)
                child = subprocess.Popen([str(spc)] + arguments, cwd=source, env=environment,
                                         stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                for line in iter(child.stdout.readline, b""):
                    text = line.decode("utf-8", errors="replace")
                    log.write(text)
                    log.flush()
                    print(text, end="", flush=True)
                if child.wait() != 0:
                    raise RuntimeError("spc_command_failed")
            run(["doctor", "--auto-fix=never", "--no-interaction"])
            extensions = list(EXTENSIONS)
            run(["download", "--for-extensions=" + ",".join(extensions + ["mbregex", "xdebug"]), "--with-php=" + minor, "--custom-url=xdebug:" + PINS["xdebug"]["url"], "--custom-url=onig:" + PINS["onig"]["url"], "--debug", "--no-interaction", "--preserve-log"])
            source_lock = json.loads((source / "downloads/.lock.json").read_text())
            # imap left PHP's core in 8.4 and comes from PECL. spc 2.8.5 extracts it and then wipes it
            # when it extracts php-src; spc skips sources already in place, so both are laid out here.
            if "imap" in extensions and tuple(map(int, minor.split("."))) >= (8, 4):
                php_src = source / "source/php-src"
                if not php_src.exists():
                    php_src.mkdir(parents=True)
                    archive = source / "downloads" / source_lock["php-src"]["filename"]
                    subprocess.run(["/usr/bin/tar", "-xf", str(archive), "-C", str(php_src), "--strip-components", "1"], check=True, env=environment)
                imap_target = php_src / "ext/imap"
                if not (imap_target / "config.m4").exists():
                    staging_imap = work / "imap"
                    staging_imap.mkdir()
                    subprocess.run(["/usr/bin/tar", "-xzf", str(source / "downloads" / source_lock["ext-imap"]["filename"]), "-C", str(staging_imap)], check=True, env=environment)
                    folder = next(p for p in staging_imap.iterdir() if p.is_dir() and (p / "config.m4").exists())
                    if imap_target.exists():
                        shutil.rmtree(imap_target)
                    shutil.move(str(folder), str(imap_target))
            xdebug_source = source / "downloads" / source_lock["xdebug"]["filename"]
            if digest(xdebug_source) != PINS["xdebug"]["sha256"]:
                raise RuntimeError("xdebug_hash_mismatch")
            onig_source = source / "downloads" / source_lock["onig"]["filename"]
            if digest(onig_source) != PINS["onig"]["sha256"]:
                raise RuntimeError("onig_hash_mismatch")
            run(["build", ",".join(extensions + ["mbregex"]), "--build-cli", "--build-fpm", "--with-libs=onig", "--build-shared=xdebug", "--with-config-file-path=" + str(home / "config/php" / minor),
                 "--with-config-file-scan-dir=" + str(home / "config/php" / minor / "conf.d"), "--debug", "--no-interaction", "--preserve-log"])
        runtime_parent = private_directory(home, "runtimes/php")
        destination = runtime_parent / minor
        if destination.exists() or destination.is_symlink():
            raise RuntimeError("runtime_exists")
        staging = Path(tempfile.mkdtemp(prefix=".install-", dir=runtime_parent))
        try:
            (staging / "bin").mkdir()
            if (source / "buildroot/license").is_dir():
                shutil.copytree(source / "buildroot/license", staging / "licenses")
            hashes = {}
            for name in ("php", "php-fpm"):
                path = source / "buildroot/bin" / name
                linked = subprocess.check_output(["/usr/bin/otool", "-L", str(path)], text=True, env=environment)
                bad = [l.strip() for l in linked.splitlines()[1:] if "/opt/homebrew/" in l or "/usr/local/" in l or str(work) in l]
                if bad:
                    raise RuntimeError("nonportable_runtime_dependency: " + name + ": " + "; ".join(bad))
                shutil.copy2(path, staging / "bin" / name)
                hashes["bin/" + name] = digest(path)
            shutil.copy2(work / "composer.download", staging / "composer.phar")
            shutil.copy2(work / "cacert.download", staging / "cacert.pem")
            hashes["composer.phar"] = PINS["composer"]["sha256"]
            hashes["cacert.pem"] = PINS["cacert"]["sha256"]
            xdebug = list((source / "buildroot").rglob("xdebug.so"))
            if xdebug:
                shutil.copy2(xdebug[0], staging / "xdebug.so")
                hashes["xdebug.so"] = digest(staging / "xdebug.so")
            php = str(staging / "bin/php")
            subprocess.run([php, "-n", "-r", "exit(function_exists('mb_split') ? 0 : 1);"], env=environment, check=True, timeout=10)
            version = subprocess.check_output([php, "-n", "-r", "echo PHP_VERSION;"], env=environment, text=True).strip()
            modules = subprocess.check_output([php, "-n", "-m"], env=environment, text=True)
            extensions = sorted({line.strip().lower().replace("zend opcache", "opcache") for line in modules.splitlines() if line.strip() and not line.startswith("[")})
            missing = sorted(set(EXTENSIONS) - set(extensions))
            # Every version ships the full set of extensions: nothing may be missing.
            if not version.startswith(minor + ".") or missing:
                raise RuntimeError("runtime_acceptance_failed")
            manifest = {"version": version, "series": minor, "architecture": "arm64", "minimum_macos": "14.0", "spc_version": PINS["spc"]["version"],
                        "built_at": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"), "extensions": extensions, "xdebug_version": PINS["xdebug"]["version"],
                        "missing_extensions": missing, "sha256": hashes, "downloads": ledger + source_ledger(source)}
            (staging / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
            staging.rename(destination)
        finally:
            if staging.exists():
                shutil.rmtree(staging)
        engine_environment = dict(environment, BUTAKE_STACK_HOME=str(home))
        response = subprocess.run([str(engine)], input=json.dumps({"method": "generatePhpIni", "series": minor}),
                                  text=True, capture_output=True, env=engine_environment, check=True, timeout=30)
        result = json.loads(response.stdout)
        if not result.get("ok"):
            raise RuntimeError("php_configuration_failed")
        # FPM must load the generated php.ini with a minimal pool of its own (temporary files only).
        verification = work / "fpm-verification.conf"
        verification.write_text("[global]\ndaemonize=no\nerror_log=" + str(work / "fpm.log") + "\n[verification]\nlisten=" + str(work / "fpm.sock") + "\npm=ondemand\npm.max_children=1\n")
        subprocess.run([str(destination / "bin/php-fpm"), "-t", "-c", result["value"], "-y", str(verification)], check=True, env=environment, timeout=30)
        print(json.dumps({"event": "build.completed", "version": version}), flush=True)
    finally:
        # Keep the evidence before deleting source/build trees, including on failure.
        try:
            source = work / "source/static-php-cli-2.8.5"
            ledger.extend(source_ledger(source))
            atomic_json(log_directory / ("php-build-" + minor + "-downloads.json"), ledger)
        finally:
            shutil.rmtree(work)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("version", choices=["8.2", "8.3", "8.4", "8.5"])
    arguments = parser.parse_args()
    default_home = Path.home() / "Library/Application Support/Butake Stack"
    home = Path(os.environ.get("BUTAKE_STACK_HOME", str(default_home))).expanduser()
    # static-php-cli does not quote paths in its shell commands: the build root must have no spaces.
    default_build = Path.home() / "Library/Caches/butake-stack-php-build"
    build_root = Path(os.environ.get("BUTAKE_STACK_BUILD_ROOT", str(default_build))).expanduser()
    if not home.is_absolute() or not build_root.is_absolute():
        raise RuntimeError("absolute_path_required")
    build(arguments.version, home, build_root)
