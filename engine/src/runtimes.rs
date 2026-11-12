use crate::store::Store;
use anyhow::{ensure, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    fs,
    io::Read,
    path::{Path, PathBuf},
};

#[derive(Debug, Serialize, Deserialize)]
pub struct PhpManifest {
    pub version: String,
    pub series: String,
    pub architecture: String,
    pub minimum_macos: String,
    pub spc_version: String,
    pub built_at: String,
    pub extensions: Vec<String>,
    pub missing_extensions: Vec<String>,
    pub sha256: BTreeMap<String, String>,
}
#[derive(Serialize)]
pub struct PhpRuntime {
    pub series: String,
    pub installed: bool,
    pub verified: bool,
    pub manifest: Option<PhpManifest>,
}
pub fn validate_series(series: &str) -> Result<()> {
    ensure!(["8.2", "8.5"].contains(&series), "unsupported_php_series");
    Ok(())
}
fn sha256(path: &Path) -> Result<String> {
    let mut file = fs::File::open(path)?;
    ensure!(
        file.metadata()?.len() <= 1024 * 1024 * 1024,
        "runtime_too_large"
    );
    let mut hash = Sha256::new();
    let mut buffer = [0; 65536];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hash.update(&buffer[..count]);
    }
    Ok(format!("{:x}", hash.finalize()))
}
pub fn manifest(store: &Store, series: &str) -> Result<PhpManifest> {
    validate_series(series)?;
    let root = store.root().join("runtimes/php").join(series);
    let canonical = root.canonicalize()?;
    ensure!(
        canonical.starts_with(store.root()) && canonical == root,
        "unsafe_runtime_path"
    );
    let path = root.join("manifest.json");
    ensure!(
        !path.symlink_metadata()?.file_type().is_symlink() && path.metadata()?.len() <= 1_048_576,
        "invalid_manifest"
    );
    let manifest: PhpManifest = serde_json::from_slice(&fs::read(path)?)?;
    ensure!(
        manifest.series == series
            && manifest.version.starts_with(&format!("{series}."))
            && manifest.architecture == "arm64",
        "invalid_manifest"
    );
    for name in ["bin/php", "bin/php-fpm", "composer.phar", "cacert.pem"] {
        ensure!(manifest.sha256.contains_key(name), "incomplete_manifest");
    }
    for (name, expected) in &manifest.sha256 {
        ensure!(
            [
                "bin/php",
                "bin/php-fpm",
                "composer.phar",
                "cacert.pem",
                "xdebug.so"
            ]
            .contains(&name.as_str()),
            "invalid_manifest_path"
        );
        let file = root.join(name).canonicalize()?;
        ensure!(
            file.starts_with(&root) && file == root.join(name),
            "unsafe_runtime_path"
        );
        ensure!(sha256(&file)? == *expected, "runtime_hash_mismatch");
    }
    Ok(manifest)
}
pub fn list(store: &Store) -> Vec<PhpRuntime> {
    ["8.2", "8.5"]
        .iter()
        .filter(|series| store.root().join("runtimes/php").join(series).exists())
        .map(|series| {
            let installed = store.root().join("runtimes/php").join(series).exists();
            let manifest = manifest(store, series).ok();
            PhpRuntime {
                series: series.to_string(),
                installed,
                verified: manifest.is_some(),
                manifest,
            }
        })
        .collect()
}
/// Installs a reviewed PHP package (`php-<version>-macos-arm64.tar.gz`) whose SHA-256 must
/// match the `catalog.json` next to it. Extraction happens in a private temporary folder and
/// the runtime only becomes visible after its manifest hashes are verified.
pub fn install_package(store: &Store, package: &Path) -> Result<PhpManifest> {
    let package = package.canonicalize()?;
    let name = package
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| anyhow::anyhow!("invalid_package"))?
        .to_string();
    ensure!(
        name.starts_with("php-") && name.ends_with("-macos-arm64.tar.gz"),
        "invalid_package"
    );
    ensure!(package.is_file(), "invalid_package");
    let catalog_path = package.with_file_name("catalog.json");
    ensure!(
        catalog_path.is_file() && catalog_path.metadata()?.len() <= 1_048_576,
        "catalog_missing"
    );
    let catalog: serde_json::Value = serde_json::from_slice(&fs::read(&catalog_path)?)?;
    let entry = catalog["entries"]
        .as_array()
        .and_then(|entries| entries.iter().find(|e| e["filename"] == name.as_str()))
        .ok_or_else(|| anyhow::anyhow!("package_not_in_catalog"))?;
    ensure!(
        entry["sha256"].as_str() == Some(sha256(&package)?.as_str()),
        "package_hash_mismatch"
    );
    let series = entry["series"].as_str().unwrap_or("").to_string();
    validate_series(&series)?;
    let runtimes = store.directory("runtimes")?;
    let php_root = runtimes.join("php");
    if !php_root.exists() {
        fs::create_dir(&php_root)?;
    }
    ensure!(
        !php_root.symlink_metadata()?.file_type().is_symlink(),
        "unsafe_runtime_path"
    );
    let target = php_root.join(&series);
    ensure!(!target.exists(), "runtime_exists");
    let staging = php_root.join(format!(".install-{series}-{}", std::process::id()));
    if staging.exists() {
        fs::remove_dir_all(&staging)?;
    }
    fs::create_dir(&staging)?;
    let result = (|| -> Result<PhpManifest> {
        // bsdtar refuses absolute paths and `..` members unless -P is given.
        let status = std::process::Command::new("/usr/bin/tar")
            .args(["-xzf"])
            .arg(&package)
            .arg("-C")
            .arg(&staging)
            .arg("--no-same-owner")
            .env_clear()
            .status()?;
        ensure!(status.success(), "package_extract_failed");
        let mut pending = vec![staging.clone()];
        while let Some(dir) = pending.pop() {
            for item in fs::read_dir(&dir)? {
                let item = item?;
                let kind = item.file_type()?;
                ensure!(!kind.is_symlink(), "unsafe_package_member");
                if kind.is_dir() {
                    pending.push(item.path());
                }
            }
        }
        fs::rename(&staging, &target)?;
        manifest(store, &series)
    })();
    if result.is_err() {
        let _ = fs::remove_dir_all(&staging);
        if target.exists() && manifest(store, &series).is_err() {
            let _ = fs::remove_dir_all(&target);
        }
    }
    result
}

pub fn generate_ini(store: &Store, series: &str) -> Result<PathBuf> {
    manifest(store, series)?;
    let config = store.directory("config")?;
    let mut directory = config;
    for part in ["php", series] {
        directory = directory.join(part);
        if !directory.exists() {
            fs::create_dir(&directory)?;
        }
        ensure!(
            !directory.symlink_metadata()?.file_type().is_symlink(),
            "unsafe_config_path"
        );
    }
    let ca = store
        .root()
        .join("runtimes/php")
        .join(series)
        .join("cacert.pem");
    // INI values must not escape a quoted string.
    let ca = ca.to_str().ok_or_else(|| anyhow::anyhow!("invalid_path"))?;
    ensure!(
        !ca.chars().any(|c| c == '"' || c == '\n' || c == '\r'),
        "invalid_ini_path"
    );
    let ini = format!("memory_limit=256M\nupload_max_filesize=64M\npost_max_size=64M\nerror_reporting=E_ALL & ~E_DEPRECATED & ~E_STRICT\ndisplay_errors=On\nlog_errors=On\nopcache.enable=1\nopcache.enable_cli=1\ncurl.cainfo=\"{ca}\"\nopenssl.cafile=\"{ca}\"\n");
    let path = directory.join("php.ini");
    let temporary = directory.join(format!("php.ini.{}.tmp", std::process::id()));
    use std::{io::Write, os::unix::fs::OpenOptionsExt};
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)?;
    file.write_all(ini.as_bytes())?;
    file.sync_all()?;
    fs::rename(temporary, &path)?;
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn checks_hashes_and_generates_ini_without_xdebug() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().to_path_buf()).unwrap();
        assert!(list(&store).iter().all(|runtime| !runtime.installed));
        let root = temp.path().join("runtimes/php/8.2");
        fs::create_dir_all(root.join("bin")).unwrap();
        let mut hashes = BTreeMap::new();
        for name in ["bin/php", "bin/php-fpm", "composer.phar", "cacert.pem"] {
            fs::write(root.join(name), name).unwrap();
            hashes.insert(name.into(), sha256(&root.join(name)).unwrap());
        }
        let manifest = PhpManifest {
            version: "8.2.30".into(),
            series: "8.2".into(),
            architecture: "arm64".into(),
            minimum_macos: "14.0".into(),
            spc_version: "2.8.5".into(),
            built_at: "2026-11-11T00:00:00Z".into(),
            extensions: vec!["pdo_mysql".into()],
            missing_extensions: vec![],
            sha256: hashes,
        };
        fs::write(
            root.join("manifest.json"),
            serde_json::to_vec(&manifest).unwrap(),
        )
        .unwrap();
        assert!(list(&store)[0].verified);
        let ini = fs::read_to_string(generate_ini(&store, "8.2").unwrap()).unwrap();
        assert!(ini.contains("memory_limit=256M") && ini.contains("curl.cainfo="));
        assert!(!ini.contains("zend_extension"));
        fs::write(root.join("bin/php"), "tampered").unwrap();
        assert!(self::manifest(&store, "8.2").is_err());
        assert!(!list(&store)[0].verified);
        assert!(generate_ini(&store, "../escape").is_err());
    }

    fn fake_package(dir: &Path, symlink: bool) -> PathBuf {
        let runtime = dir.join("runtime");
        fs::create_dir_all(runtime.join("bin")).unwrap();
        let mut hashes: BTreeMap<String, String> = BTreeMap::new();
        for name in ["bin/php", "bin/php-fpm", "composer.phar", "cacert.pem"] {
            fs::write(runtime.join(name), name).unwrap();
            hashes.insert(name.into(), sha256(&runtime.join(name)).unwrap());
        }
        if symlink {
            std::os::unix::fs::symlink("/etc/hosts", runtime.join("evil")).unwrap();
        }
        let manifest = serde_json::json!({"version":"8.2.35","series":"8.2","architecture":"arm64",
            "minimum_macos":"14.0","spc_version":"2.8.5","built_at":"2026-11-11T00:00:00Z",
            "extensions":["pdo_mysql"],"missing_extensions":[],"sha256":hashes});
        fs::write(runtime.join("manifest.json"), manifest.to_string()).unwrap();
        let out = dir.join("out");
        fs::create_dir_all(&out).unwrap();
        let package = out.join("php-8.2.35-macos-arm64.tar.gz");
        let status = std::process::Command::new("/usr/bin/tar")
            .arg("-czf").arg(&package).arg("-C").arg(&runtime).arg(".")
            .status().unwrap();
        assert!(status.success());
        let catalog = serde_json::json!({"schema_version":1,"entries":[{"filename":"php-8.2.35-macos-arm64.tar.gz",
            "series":"8.2","sha256":sha256(&package).unwrap()}]});
        fs::write(out.join("catalog.json"), catalog.to_string()).unwrap();
        package
    }
    #[test]
    fn installs_verified_packages_only() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        let good = fake_package(&temp.path().join("good"), false);
        let manifest = install_package(&store, &good).unwrap();
        assert_eq!(manifest.version, "8.2.35");
        assert!(list(&store)[0].verified);
        assert!(install_package(&store, &good).is_err(), "never overwrites");

        let other = Store::new(temp.path().join("other")).unwrap();
        let evil = fake_package(&temp.path().join("evil"), true);
        assert!(install_package(&other, &evil).is_err());
        assert!(!other.root().join("runtimes/php/8.2").exists());

        let tampered = fake_package(&temp.path().join("tampered"), false);
        fs::write(&tampered, b"not the package").unwrap();
        assert!(install_package(&other, &tampered).is_err());
    }
}

/// PHP builds of Butake Stack (static-php-cli, arm64), published with their SHA-256 in the release
/// `runtimes` of the project's repository. The catalog lists them; the user picks which to install.
pub const RUNTIMES_RELEASE: &str = "https://github.com/Jose-Currinir/Butake-Stack/releases/download/runtimes";

pub fn php_catalog() -> Result<Vec<serde_json::Value>> {
    let data = crate::tools::fetch(&format!("{RUNTIMES_RELEASE}/catalog.json"), 1_048_576)?;
    let catalog: serde_json::Value = serde_json::from_slice(&data)?;
    Ok(catalog["entries"]
        .as_array()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter(|e| e["family"] == "php" && e["architecture"] == "arm64")
        .collect())
}

/// Downloads one PHP build from the catalog and installs it like a local package (the SHA-256 in
/// the catalog must match), then writes its php.ini.
pub fn download_php(store: &Store, version: &str) -> Result<PhpManifest> {
    ensure!(
        !version.is_empty() && version.len() <= 20 && version.bytes().all(|c| c.is_ascii_digit() || c == b'.'),
        "invalid_version"
    );
    let data = crate::tools::fetch(&format!("{RUNTIMES_RELEASE}/catalog.json"), 1_048_576)?;
    let catalog: serde_json::Value = serde_json::from_slice(&data)?;
    let entry = catalog["entries"]
        .as_array()
        .and_then(|entries| entries.iter().find(|e| e["version"] == version && e["architecture"] == "arm64"))
        .ok_or_else(|| anyhow::anyhow!("version_not_in_catalog"))?;
    let filename = entry["filename"].as_str().unwrap_or("");
    ensure!(
        filename == format!("php-{version}-macos-arm64.tar.gz"),
        "invalid_package"
    );
    let work = store.directory("downloads")?.join(format!("php-{version}-{}", std::process::id()));
    if work.exists() {
        fs::remove_dir_all(&work)?;
    }
    fs::create_dir(&work)?;
    let result = (|| -> Result<PhpManifest> {
        fs::write(work.join("catalog.json"), &data)?;
        crate::tools::download(&format!("{RUNTIMES_RELEASE}/{filename}"), &work.join(filename))?;
        let manifest = install_package(store, &work.join(filename))?;
        generate_ini(store, &manifest.series)?;
        Ok(manifest)
    })();
    let _ = fs::remove_dir_all(&work);
    result
}
