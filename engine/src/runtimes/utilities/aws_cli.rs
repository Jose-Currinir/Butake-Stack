//! AWS CLI v2: the official package, checked and unpacked into the user's home.

use super::*;

/// As AWS's install.sh does for one user: the version in `v2/version.txt`, its versioned package,
/// whose signature must be AWS's team and notarized. The package is expanded, never run, and its
/// `aws-cli` folder goes to `~/.local/share/aws-cli` with `aws` and `aws_completer` linked in
/// `~/.local/bin` (what the package's own script leaves, without running it).
pub(super) fn install_aws(store: &Store, dir: &Path) -> Result<Value> {
    progress::step("download");
    let version = fetch_text(&format!("{AWS_BASE}/v2/version.txt"), 100)?;
    ensure!(valid_version(&version), "unexpected_artifact");
    let pkg = dir.join(format!("AWSCLIV2-{version}.pkg"));
    devtools::log(store, "aws", &format!("descargando AWS CLI {version}"));
    download::download(&format!("{AWS_BASE}/AWSCLIV2-{version}.pkg"), &pkg)?;
    place_aws(store, &pkg, &version)
}

pub(super) fn place_aws(store: &Store, pkg: &Path, version: &str) -> Result<Value> {
    progress::step("verifyPackage");
    signature::verify_package(pkg, AWS_TEAM)?;
    let expanded = pkg.with_extension("expanded");
    let _ = fs::remove_dir_all(&expanded);
    let result = (|| -> Result<Value> {
        archive::expand_pkg(pkg, &expanded, "extract_failed")?;
        let payload = expanded.join("aws-cli.pkg/Payload/aws-cli");
        ensure!(payload.join("aws").is_file(), "unexpected_artifact");
        archive::check_tree(&payload, archive::Links::Inside)?;
        for program in ["aws", "aws_completer"] {
            signature::verify_code(&payload.join(program), AWS_TEAM, false)?;
        }
        devtools::log(
            store,
            "aws",
            &format!(
                "firma del paquete y de sus programas (AWS, {AWS_TEAM}) y notarización de Apple verificadas"
            ),
        );
        progress::check()?;
        progress::fixed_step("install");
        let home = home()?;
        let share = home.join(".local/share");
        fs::create_dir_all(&share)?;
        let target = share.join("aws-cli");
        let stage = share.join(".aws-cli.butake");
        let _ = fs::remove_dir_all(&stage);
        archive::copy_tree(&payload, &stage, "extract_failed")?;
        if fs::symlink_metadata(&target).is_ok() {
            fs::remove_dir_all(&target)?;
        }
        fs::rename(&stage, &target)?;
        let bin = home.join(".local/bin");
        fs::create_dir_all(&bin)?;
        // What the package's script writes for a per-user install, so `aws` knows where it lives.
        let data = target.join("awscli/data");
        if data.is_dir() {
            fs::write(
                data.join("install.json"),
                serde_json::to_string_pretty(&json!({"install_dir": target, "bin_dir": bin}))?,
            )?;
        }
        let aws = bin.join("aws");
        let completer = bin.join("aws_completer");
        crate::runtimes::languages::toolchains::replace_link(&target.join("aws"), &aws)?;
        crate::runtimes::languages::toolchains::replace_link(
            &target.join("aws_completer"),
            &completer,
        )?;
        check_reported(&aws, version)?;
        record(store, "aws", version, vec![aws.clone(), completer, target])?;
        Ok(json!({"version": version, "path": aws}))
    })();
    let _ = fs::remove_dir_all(&expanded);
    result
}
