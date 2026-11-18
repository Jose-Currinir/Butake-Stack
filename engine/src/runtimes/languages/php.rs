use crate::core::archive::{self, Links};
use crate::core::fsutil::write_private;
use crate::core::hash;
use crate::core::json;
use crate::core::progress;
use crate::core::store::Store;
use crate::core::time::now_secs;
use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs,
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
    /// The build ships `xdebug.so` (verified with the manifest).
    pub xdebug: bool,
    /// Xdebug mode in use for this line, if it is on.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub xdebug_mode: Option<String>,
}
pub fn validate_series(series: &str) -> Result<()> {
    // Any PHP line "<major>.<minor>" from 8.1 on: the published catalog decides what exists, so
    // an older Stack can install a PHP released after it.
    let mut parts = series.split('.');
    let (major, minor) = (
        parts.next().and_then(|p| p.parse::<u32>().ok()),
        parts.next().and_then(|p| p.parse::<u32>().ok()),
    );
    ensure!(
        parts.next().is_none()
            && series.len() <= 5
            && matches!(
                (major, minor),
                (Some(8), Some(1..=99)) | (Some(9..=19), Some(0..=99))
            ),
        "unsupported_php_series"
    );
    Ok(())
}
/// SHA-256 of a runtime file; anything above 1 GiB is refused before it is read.
fn file_digest(path: &Path) -> Result<String> {
    ensure!(
        fs::metadata(path)?.len() <= 1024 * 1024 * 1024,
        "runtime_too_large"
    );
    hash::sha256_file(path)
}
pub fn manifest(store: &Store, series: &str) -> Result<PhpManifest> {
    validate_series(series)?;
    verify_runtime(&store.root().join("runtimes/php").join(series), series)
}
/// Verifies the runtime folder `root` (the installed line, or its staging copy before it becomes
/// visible): its manifest, the paths it lists and the SHA-256 of every file.
fn verify_runtime(root: &Path, series: &str) -> Result<PhpManifest> {
    let canonical = root.canonicalize()?;
    ensure!(canonical == root, "unsafe_runtime_path");
    let path = root.join("manifest.json");
    ensure!(
        !path.symlink_metadata()?.file_type().is_symlink() && path.metadata()?.len() <= 1_048_576,
        "invalid_manifest"
    );
    let manifest: PhpManifest = json::read(&path)?;
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
            file.starts_with(root) && file == root.join(name),
            "unsafe_runtime_path"
        );
        ensure!(file_digest(&file)? == *expected, "runtime_hash_mismatch");
    }
    Ok(manifest)
}
pub fn list(store: &Store) -> Vec<PhpRuntime> {
    // Every installed line, newest first (8.3, 8.4… appear as soon as they are installed).
    let mut series: Vec<String> = fs::read_dir(store.root().join("runtimes/php"))
        .map(|entries| {
            entries
                .filter_map(|e| e.ok()?.file_name().into_string().ok())
                .filter(|s| validate_series(s).is_ok())
                .collect()
        })
        .unwrap_or_default();
    series.sort_by(|a, b| b.cmp(a));
    let modes = store.config().map(|c| c.xdebug).unwrap_or_default();
    series
        .iter()
        .map(|series| {
            let installed = store.root().join("runtimes/php").join(series).exists();
            let manifest = manifest(store, series).ok();
            let xdebug = manifest
                .as_ref()
                .is_some_and(|m| m.sha256.contains_key("xdebug.so"));
            PhpRuntime {
                series: series.to_string(),
                installed,
                verified: manifest.is_some(),
                xdebug,
                xdebug_mode: modes.get(series).filter(|_| xdebug).cloned(),
                manifest,
            }
        })
        .collect()
}
/// Removes an installed PHP line (P-42): its runtime, its generated `php.ini` folder and its
/// Xdebug setting. Refused while it is the global line or a project or the terminal uses it
/// (`runtime_global`, `runtime_in_use:<names>`), like the other languages.
pub fn remove(store: &Store, series: &str) -> Result<()> {
    validate_series(series)?;
    let installed: Vec<String> = list(store)
        .into_iter()
        .filter(|runtime| runtime.installed)
        .map(|runtime| runtime.series)
        .collect();
    ensure!(installed.iter().any(|s| s == series), "php_not_installed");
    let others: Vec<String> = installed.into_iter().filter(|s| s != series).collect();
    crate::runtimes::languages::usage::ensure_unused(store, "php", series, &others)?;
    let terminal = crate::runtimes::languages::toolchains::terminal_status(store);
    ensure!(
        terminal["php"]["version"].as_str() != Some(series),
        "runtime_in_use:Terminal"
    );
    let root = store.root().join("runtimes/php");
    let target = root.join(series);
    ensure!(
        target.symlink_metadata()?.is_dir() && target.canonicalize()?.starts_with(&root),
        "unsafe_runtime_path"
    );
    fs::remove_dir_all(&target)?;
    let generated = store.root().join("config/php").join(series);
    if generated.symlink_metadata().is_ok_and(|m| m.is_dir()) {
        fs::remove_dir_all(&generated)?;
    }
    if store.config()?.xdebug.contains_key(series) {
        store.update_config(|config| {
            config.xdebug.remove(series);
            Ok(())
        })?;
    }
    Ok(())
}

/// The steps an install reports (see `progress`): from the catalog, or a package on this Mac.
pub const DOWNLOAD_PLAN: [&str; 3] = ["download", "verifySum", "install"];
pub const PACKAGE_PLAN: [&str; 2] = ["verifySum", "install"];

/// Installs a reviewed PHP package (`php-<version>-macos-arm64.tar.gz`) whose SHA-256 must
/// match the `catalog.json` next to it (a package the user picked on this Mac; the signature
/// applies to the downloaded catalog, see `download_php`). Extraction happens in a private temporary folder and
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
    let catalog: serde_json::Value = json::read(&catalog_path)?;
    let entry = catalog["entries"]
        .as_array()
        .and_then(|entries| entries.iter().find(|e| e["filename"] == name.as_str()))
        .ok_or_else(|| anyhow::anyhow!("package_not_in_catalog"))?;
    progress::step("verifySum");
    ensure!(
        entry["sha256"].as_str() == Some(file_digest(&package)?.as_str()),
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
        progress::check()?;
        progress::fixed_step("install");
        archive::extract_tar_gz(&package, &staging, false, "package_extract_failed")?;
        archive::check_tree(&staging, Links::Forbid)?;
        // Everything is verified in staging: the runtime only appears once its files match.
        let manifest = verify_runtime(&staging, &series)?;
        fs::rename(&staging, &target)?;
        Ok(manifest)
    })();
    if result.is_err() {
        let _ = fs::remove_dir_all(&staging);
        if target.exists() && manifest(store, &series).is_err() {
            let _ = fs::remove_dir_all(&target);
        }
    }
    result
}

/// Lines added to php.ini when Xdebug is on for a line. The extension is the verified file of the
/// runtime (its hash is in the manifest); the debugger only connects to 127.0.0.1 and only when the
/// request asks for it (`XDEBUG_SESSION`, the browser extension or `XDEBUG_TRIGGER`).
pub fn xdebug_ini(extension: &str, mode: &str) -> Result<String> {
    ensure!(
        crate::core::model::XDEBUG_MODES.contains(&mode),
        "invalid_xdebug"
    );
    ensure!(
        !extension.chars().any(|c| c == '"' || c.is_control()),
        "invalid_ini_path"
    );
    Ok(format!(
        "zend_extension=\"{extension}\"\nxdebug.mode={mode}\nxdebug.start_with_request=trigger\n\
         xdebug.client_host=127.0.0.1\nxdebug.client_port=9003\nxdebug.discover_client_host=false\n"
    ))
}

pub fn generate_ini(store: &Store, series: &str) -> Result<PathBuf> {
    let runtime = manifest(store, series)?;
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
    let mut ini = format!(
        "memory_limit=256M\nupload_max_filesize=64M\npost_max_size=64M\nerror_reporting=E_ALL & ~E_DEPRECATED & ~E_STRICT\ndisplay_errors=On\nlog_errors=On\nopcache.enable=1\nopcache.enable_cli=1\ncurl.cainfo=\"{ca}\"\nopenssl.cafile=\"{ca}\"\n"
    );
    let mode = store
        .config()
        .ok()
        .and_then(|c| c.xdebug.get(series).cloned());
    if let (Some(mode), true) = (mode, runtime.sha256.contains_key("xdebug.so")) {
        let extension = store
            .root()
            .join("runtimes/php")
            .join(series)
            .join("xdebug.so");
        ini.push_str(&xdebug_ini(
            extension
                .to_str()
                .ok_or_else(|| anyhow::anyhow!("invalid_path"))?,
            &mode,
        )?);
    }
    let path = directory.join("php.ini");
    write_private(&path, &ini)?;
    Ok(path)
}

/// PHP builds of Stack (static-php-cli, arm64), published with their SHA-256 in the release
/// `runtimes` of the project's repository. The catalog lists them; the user picks which to install.
pub const RUNTIMES_RELEASE: &str =
    "https://github.com/Jose-Currinir/Butake-Stack/releases/download/runtimes";

/// Public key (uncompressed X9.63 point, hex) of the ECDSA P-256 key that signs `catalog.json`.
/// The private half stays with the publisher (`scripts/php/sign_catalog.py`); rotating the key
/// means shipping a new Stack. A catalog without a valid signature by this key is never used.
const CATALOG_PUBLIC_KEY: &str = "046ea9e5085d7b1848dc0e064d396a057de3bfd53ea5124567f2c17b3e8c2cf5284d42ddccd40761228f305da9dffd7b46607f5876334df3ea6d898ad836c288fc";

fn decode_hex(text: &str) -> Result<Vec<u8>> {
    ensure!(
        text.len().is_multiple_of(2) && text.is_ascii(),
        "invalid_public_key"
    );
    (0..text.len())
        .step_by(2)
        .map(|i| {
            u8::from_str_radix(&text[i..i + 2], 16)
                .map_err(|_| anyhow::anyhow!("invalid_public_key"))
        })
        .collect()
}

/// Checks `data` (the bytes of `catalog.json`) against its DER signature made with the key
/// `public_key_hex`. No signature is `catalog_unsigned`; a signature that does not match is
/// `catalog_signature_invalid`.
fn verify_catalog(public_key_hex: &str, data: &[u8], signature: Option<&[u8]>) -> Result<()> {
    let signature = match signature {
        Some(signature) if !signature.is_empty() => signature,
        _ => anyhow::bail!("catalog_unsigned"),
    };
    crate::core::ecdsa::verify(&decode_hex(public_key_hex)?, data, signature)
        .map_err(|_| anyhow::anyhow!("catalog_signature_invalid"))
}

/// The catalog URLs carry a value that changes every 10 minutes: GitHub's download CDN can keep
/// serving a replaced asset for a long time; the local cache keeps requests rare anyway. Both
/// files use the same value so they come from the same moment.
fn catalog_urls() -> (String, String) {
    let bucket = now_secs() / 600;
    (
        format!("{RUNTIMES_RELEASE}/catalog.json?t={bucket}"),
        format!("{RUNTIMES_RELEASE}/catalog.json.sig?t={bucket}"),
    )
}

/// Downloads `catalog.json` and its signature and returns the catalog bytes with their parsed
/// form, only when the signature is valid.
fn fetch_catalog() -> Result<(Vec<u8>, serde_json::Value)> {
    let (catalog_url, signature_url) = catalog_urls();
    let data = crate::core::download::fetch(&catalog_url, 1_048_576)?;
    // A DER ECDSA P-256 signature is 70-72 bytes; a missing file is an unsigned catalog.
    let signature = crate::core::download::fetch(&signature_url, 1024).ok();
    verify_catalog(CATALOG_PUBLIC_KEY, &data, signature.as_deref())?;
    let catalog = serde_json::from_slice(&data)?;
    Ok((data, catalog))
}

pub fn php_catalog() -> Result<Vec<serde_json::Value>> {
    let (_, catalog) = fetch_catalog()?;
    Ok(catalog["entries"]
        .as_array()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter(|e| e["family"] == "php" && e["architecture"] == "arm64")
        .collect())
}

/// Downloads one PHP build from the signed catalog and installs it like a local package (the
/// SHA-256 in the catalog must match), then writes its php.ini.
pub fn download_php(store: &Store, version: &str) -> Result<PhpManifest> {
    ensure!(
        !version.is_empty()
            && version.len() <= 20
            && version.bytes().all(|c| c.is_ascii_digit() || c == b'.'),
        "invalid_version"
    );
    progress::step("download");
    let (data, catalog) = fetch_catalog()?;
    let entry = catalog["entries"]
        .as_array()
        .and_then(|entries| {
            entries
                .iter()
                .find(|e| e["version"] == version && e["architecture"] == "arm64")
        })
        .ok_or_else(|| anyhow::anyhow!("version_not_in_catalog"))?;
    let filename = entry["filename"].as_str().unwrap_or("");
    ensure!(
        filename == format!("php-{version}-macos-arm64.tar.gz"),
        "invalid_package"
    );
    let work = store
        .directory("downloads")?
        .join(format!("php-{version}-{}", std::process::id()));
    if work.exists() {
        fs::remove_dir_all(&work)?;
    }
    fs::create_dir(&work)?;
    let result = (|| -> Result<PhpManifest> {
        fs::write(work.join("catalog.json"), &data)?;
        crate::core::download::download(
            &format!("{RUNTIMES_RELEASE}/{filename}"),
            &work.join(filename),
        )?;
        let manifest = install_package(store, &work.join(filename))?;
        generate_ini(store, &manifest.series)?;
        Ok(manifest)
    })();
    let _ = fs::remove_dir_all(&work);
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A PHP line goes with its php.ini folder and Xdebug setting; never the global line nor one
    /// a project uses, and only one that is installed.
    #[test]
    fn removes_a_php_line_nobody_uses() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::new(temp.path().join("store")).unwrap();
        for series in ["8.2", "8.5"] {
            fs::create_dir_all(store.root().join("runtimes/php").join(series).join("bin")).unwrap();
            fs::create_dir_all(store.root().join("config/php").join(series)).unwrap();
        }
        let mut config = store.config().unwrap();
        config.xdebug.insert("8.5".into(), "debug".into());
        store.save_config(&config).unwrap();
        let folder = temp.path().join("tienda");
        fs::create_dir_all(&folder).unwrap();
        let project: crate::core::model::Project = serde_json::from_value(serde_json::json!({
            "id": "tienda", "name": "Tienda", "path": folder, "domains": ["tienda.test"],
            "https": false, "kind": "php", "runtime": {"php": "8.5"}, "docroot": ".",
            "services": [], "databases": [], "processes": []}))
        .unwrap();
        store.save(project.clone()).unwrap();
        assert_eq!(
            remove(&store, "8.5").unwrap_err().to_string(),
            "runtime_in_use:Tienda"
        );
        assert_eq!(
            remove(&store, "8.2").unwrap_err().to_string(),
            "runtime_global"
        );
        assert_eq!(
            remove(&store, "8.4").unwrap_err().to_string(),
            "php_not_installed"
        );
        let mut project = project;
        project.runtime.clear();
        store.save(project).unwrap();
        remove(&store, "8.5").unwrap();
        assert!(!store.root().join("runtimes/php/8.5").exists());
        assert!(!store.root().join("config/php/8.5").exists());
        assert!(store.root().join("runtimes/php/8.2").is_dir());
        assert!(store.config().unwrap().xdebug.is_empty());
    }

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
            hashes.insert(name.into(), file_digest(&root.join(name)).unwrap());
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
        // Xdebug on for 8.2: only loaded when the build ships it.
        let mut config = store.config().unwrap();
        config.xdebug.insert("8.2".into(), "debug".into());
        store.save_config(&config).unwrap();
        let ini = fs::read_to_string(generate_ini(&store, "8.2").unwrap()).unwrap();
        assert!(
            !ini.contains("zend_extension"),
            "no xdebug.so in this build"
        );
        fs::write(root.join("xdebug.so"), "so").unwrap();
        let mut with = serde_json::to_value(self::manifest(&store, "8.2").unwrap()).unwrap();
        with["sha256"]["xdebug.so"] = file_digest(&root.join("xdebug.so")).unwrap().into();
        fs::write(root.join("manifest.json"), with.to_string()).unwrap();
        let ini = fs::read_to_string(generate_ini(&store, "8.2").unwrap()).unwrap();
        assert!(ini.contains("xdebug.so\"\nxdebug.mode=debug\nxdebug.start_with_request=trigger"));
        assert!(list(&store)[0].xdebug && list(&store)[0].xdebug_mode.as_deref() == Some("debug"));
        assert!(xdebug_ini("/x", "evil\nauto_prepend_file=/tmp/x").is_err());
        config.xdebug.clear();
        store.save_config(&config).unwrap();
        assert!(
            !fs::read_to_string(generate_ini(&store, "8.2").unwrap())
                .unwrap()
                .contains("xdebug")
        );
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
            hashes.insert(name.into(), file_digest(&runtime.join(name)).unwrap());
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
            .arg("-czf")
            .arg(&package)
            .arg("-C")
            .arg(&runtime)
            .arg(".")
            .status()
            .unwrap();
        assert!(status.success());
        let catalog = serde_json::json!({"schema_version":1,"entries":[{"filename":"php-8.2.35-macos-arm64.tar.gz",
            "series":"8.2","sha256":file_digest(&package).unwrap()}]});
        fs::write(out.join("catalog.json"), catalog.to_string()).unwrap();
        package
    }
    #[test]
    fn installs_verified_packages_only() {
        // It reports its steps: not while another test follows an install.
        let _turn = progress::TEST_TURN
            .lock()
            .unwrap_or_else(|e| e.into_inner());
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

    /// A throwaway P-256 key made with openssl in `dir`: the public X9.63 point (hex) and a
    /// function that signs bytes with the private half. Never the publisher's key.
    fn test_key(dir: &Path) -> (String, impl Fn(&[u8]) -> Vec<u8> + use<>) {
        const OPENSSL: &str = "/usr/bin/openssl";
        fs::create_dir_all(dir).unwrap();
        let key = dir.join("key.pem");
        let run = |args: &[&str]| {
            let out = std::process::Command::new(OPENSSL)
                .args(args)
                .output()
                .unwrap();
            assert!(out.status.success(), "{args:?}");
            out.stdout
        };
        run(&[
            "ecparam",
            "-name",
            "prime256v1",
            "-genkey",
            "-noout",
            "-out",
            key.to_str().unwrap(),
        ]);
        let spki = run(&[
            "ec",
            "-in",
            key.to_str().unwrap(),
            "-pubout",
            "-outform",
            "DER",
        ]);
        let point = &spki[spki.len() - 65..];
        let hex: String = point.iter().map(|b| format!("{b:02x}")).collect();
        let dir = dir.to_path_buf();
        let sign = move |data: &[u8]| {
            let input = dir.join("data.bin");
            fs::write(&input, data).unwrap();
            run(&[
                "dgst",
                "-sha256",
                "-sign",
                dir.join("key.pem").to_str().unwrap(),
                input.to_str().unwrap(),
            ])
        };
        (hex, sign)
    }

    #[test]
    fn catalog_needs_a_valid_signature_of_the_publisher_key() {
        let temp = tempfile::tempdir().unwrap();
        let (key, sign) = test_key(&temp.path().join("a"));
        let catalog = br#"{"schema_version":1,"entries":[]}"#;
        let signature = sign(catalog);
        verify_catalog(&key, catalog, Some(&signature)).unwrap();

        let changed = br#"{"schema_version":1,"entries":[{"id":"evil"}]}"#;
        assert_eq!(
            verify_catalog(&key, changed, Some(&signature))
                .unwrap_err()
                .to_string(),
            "catalog_signature_invalid"
        );
        for missing in [None, Some(&[][..])] {
            assert_eq!(
                verify_catalog(&key, catalog, missing)
                    .unwrap_err()
                    .to_string(),
                "catalog_unsigned"
            );
        }
        let (other, other_sign) = test_key(&temp.path().join("b"));
        assert_ne!(key, other);
        assert_eq!(
            verify_catalog(&key, catalog, Some(&other_sign(catalog)))
                .unwrap_err()
                .to_string(),
            "catalog_signature_invalid"
        );
        assert_eq!(
            verify_catalog(&key, catalog, Some(b"not a signature"))
                .unwrap_err()
                .to_string(),
            "catalog_signature_invalid"
        );
    }

    #[test]
    fn embedded_public_key_is_a_valid_p256_point() {
        let key = decode_hex(CATALOG_PUBLIC_KEY).unwrap();
        assert_eq!((key.len(), key[0]), (65, 4));
    }
}
