"""Prepare reviewed PHP packages and a local distribution catalog; never publish."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def package(runtime, output):
    runtime = runtime.resolve(strict=True)
    manifest_path = runtime / "manifest.json"
    if manifest_path.is_symlink() or manifest_path.stat().st_size > 1024 * 1024:
        raise RuntimeError("invalid_manifest")
    manifest = json.loads(manifest_path.read_text())
    series = manifest["series"]
    version = manifest["version"]
    if series not in ("8.2", "8.5") or not re.fullmatch(re.escape(series) + r"\.\d+", version) or manifest["architecture"] != "arm64":
        raise RuntimeError("unsupported_runtime")
    allowed = {"bin/php", "bin/php-fpm", "composer.phar", "cacert.pem", "xdebug.so"}
    required = allowed - {"xdebug.so"}
    if not required <= set(manifest["sha256"]) <= allowed:
        raise RuntimeError("incomplete_manifest")
    for name, expected in manifest["sha256"].items():
        path = runtime / name
        if path.resolve(strict=True) != path or digest(path) != expected:
            raise RuntimeError("runtime_hash_mismatch")
    # This caught a real Laravel incompatibility even when php -m looked complete.
    subprocess.run([str(runtime / "bin/php"), "-n", "-r", "exit(function_exists('mb_split') ? 0 : 1);"], check=True, timeout=10,
                   env={"PATH": "/usr/bin:/bin", "HOME": str(runtime)})
    files = [manifest_path] + [runtime / name for name in manifest["sha256"]]
    license_root = runtime / "licenses"
    if license_root.is_dir() and not license_root.is_symlink():
        for path in license_root.rglob("*"):
            if path.is_symlink():
                raise RuntimeError("unsafe_license_path")
            if path.is_file():
                files.append(path)
    else:
        raise RuntimeError("missing_license_notices")
    output.mkdir(parents=True, exist_ok=True)
    output = output.resolve()
    filename = "php-" + version + "-macos-arm64.tar.gz"
    target = output / filename
    descriptor, temporary = tempfile.mkstemp(prefix=".package-", dir=output)
    try:
        with os.fdopen(descriptor, "wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                    for path in sorted(files):
                        info = archive.gettarinfo(str(path), str(path.relative_to(runtime)))
                        info.uid = info.gid = 0
                        info.uname = info.gname = ""
                        info.mtime = 0
                        info.mode = 0o755 if str(path.relative_to(runtime)) in ("bin/php", "bin/php-fpm") else 0o644
                        with path.open("rb") as source:
                            archive.addfile(info, source)
            raw.flush()
            os.fsync(raw.fileno())
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    entry = {"id": "php-" + version + "-macos-arm64", "family": "php", "series": series, "version": version,
             "architecture": "arm64", "minimum_macos": manifest["minimum_macos"], "filename": filename,
             "size_bytes": target.stat().st_size, "sha256": digest(target), "download_url": None,
             "source": "Butake Stack / static-php-cli " + manifest["spc_version"]}
    catalog_path = output / "catalog.json"
    catalog = json.loads(catalog_path.read_text()) if catalog_path.exists() else {"schema_version": 1, "entries": []}
    catalog["entries"] = sorted([item for item in catalog["entries"] if item["id"] != entry["id"]] + [entry], key=lambda item: item["id"])
    descriptor, temporary = tempfile.mkstemp(prefix=".catalog-", dir=output)
    try:
        with os.fdopen(descriptor, "w") as file:
            json.dump(catalog, file, indent=2)
            file.write("\n")
        os.replace(temporary, catalog_path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(json.dumps(entry, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("runtime", type=Path)
    parser.add_argument("output", type=Path)
    arguments = parser.parse_args()
    package(arguments.runtime, arguments.output)
