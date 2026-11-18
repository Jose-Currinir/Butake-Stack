//! The built files into the engine: libraries relinked to `@loader_path` and signed ad hoc, then each file written beside its place and renamed over it.

use super::*;

/// From `file`'s folder to the engine's `lib/`, as `@loader_path` wants it.
pub(super) fn up_to_lib(rel: &str) -> String {
    let parent = Path::new(rel).parent().unwrap_or(Path::new(""));
    let depth = parent.components().count();
    if parent == Path::new("lib") {
        String::new()
    } else if parent.starts_with("lib") {
        "../".repeat(depth - 1)
    } else {
        format!("{}lib/", "../".repeat(depth))
    }
}

/// Points every library a new Mach-O file loads from the work folder (or through `@rpath`) to the
/// engine's own `lib/`, drops search paths into the work folder, signs it ad hoc and checks that
/// the work folder's path is gone. Other files are left as they are.
pub(super) fn relink(pg: &Path, rel: &str, work: &Path) -> Result<()> {
    let result = relink_file(pg, rel, work);
    if result.is_err() {
        note(&format!(
            "No se pudo dejar lista {rel} para la carpeta del servicio."
        ));
    }
    result
}

/// One line of its own in the followed operation's log.
pub(super) fn note(line: &str) {
    let _ = Command::new("/bin/echo")
        .arg(line)
        .env_clear()
        .stdout(progress::output())
        .status();
}

pub(super) fn relink_file(pg: &Path, rel: &str, work: &Path) -> Result<()> {
    let file = pg.join(rel);
    let listed = Command::new("/usr/bin/otool")
        .arg("-L")
        .arg(&file)
        .env_clear()
        .stderr(Stdio::null())
        .output()?;
    let text = String::from_utf8_lossy(&listed.stdout).into_owned();
    if !listed.status.success() || !text.contains("(compatibility version") {
        return Ok(());
    }
    let work_text = work.to_string_lossy().into_owned();
    let name = file
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    // A library has an id of its own (listed first by `otool -L`); a module PostgreSQL loads is a
    // bundle, even when it is called `.dylib`, and has none.
    let id = Command::new("/usr/bin/otool")
        .arg("-D")
        .arg(&file)
        .env_clear()
        .stderr(Stdio::null())
        .output()?;
    let is_dylib = String::from_utf8_lossy(&id.stdout).lines().nth(1).is_some();
    let tool = |args: Vec<String>| -> Result<()> {
        let status = Command::new("/usr/bin/install_name_tool")
            .args(args)
            .arg(&file)
            .env_clear()
            .stderr(Stdio::null())
            .status()?;
        ensure!(status.success(), "relocate_failed");
        Ok(())
    };
    for (index, line) in text.lines().skip(1).enumerate() {
        let Some(dep) = line.trim().split(" (").next() else {
            continue;
        };
        let base = Path::new(dep)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        if is_dylib && index == 0 {
            continue; // a library lists its own id first; it is set below
        }
        if dep.starts_with(&work_text) || dep.starts_with("@rpath/") {
            if !pg.join("lib").join(&base).exists() {
                note(&format!("{rel} carga {base}, que no está en lib/."));
                bail!("relocate_failed");
            }
            tool(vec![
                "-change".into(),
                dep.into(),
                format!("@loader_path/{}{base}", up_to_lib(rel)),
            ])?;
        }
    }
    if is_dylib {
        tool(vec!["-id".into(), format!("@rpath/{name}")])?;
    }
    for path in rpaths(&file)? {
        if path.starts_with(&work_text) {
            tool(vec!["-delete_rpath".into(), path])?;
        }
    }
    let status = Command::new("/usr/bin/codesign")
        .args(["--force", "--sign", "-"])
        .arg(&file)
        .env_clear()
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()?;
    ensure!(status.success(), "resign_failed");
    // `-X`: without the file's own path as a heading.
    let again = Command::new("/usr/bin/otool")
        .args(["-X", "-L", "-l"])
        .arg(&file)
        .env_clear()
        .stderr(Stdio::null())
        .output()?;
    let text = String::from_utf8_lossy(&again.stdout).into_owned();
    if let Some(line) = text.lines().find(|l| l.contains(&work_text)) {
        note(&format!(
            "{rel} aún nombra la carpeta de trabajo: {}",
            line.trim()
        ));
        bail!("relocate_failed");
    }
    Ok(())
}

pub(super) fn rpaths(file: &Path) -> Result<Vec<String>> {
    let out = Command::new("/usr/bin/otool")
        .arg("-l")
        .arg(file)
        .env_clear()
        .stderr(Stdio::null())
        .output()?;
    let text = String::from_utf8_lossy(&out.stdout).into_owned();
    let mut found = vec![];
    let mut in_rpath = false;
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with("cmd ") {
            in_rpath = line == "cmd LC_RPATH";
        } else if in_rpath && let Some(rest) = line.strip_prefix("path ") {
            found.push(rest.split(" (offset").next().unwrap_or("").to_string());
        }
    }
    Ok(found)
}

/// The built files into the engine: each one written next to its place and renamed over it, so a
/// running server never reads half a file. Files the previous version had and this one does not
/// go away (unless another extension also placed them).
pub(super) fn place(
    root: &Path,
    built: &Path,
    files: &[String],
    previous: Option<&Installed>,
    current: &State,
) -> Result<()> {
    let mut placed = vec![];
    let result = (|| -> Result<()> {
        for rel in files {
            ensure!(safe_relative(rel), "unsafe_package_member");
            let from = built.join(rel);
            let to = root.join(rel);
            if let Some(parent) = to.parent() {
                fs::create_dir_all(parent)?;
            }
            let name = to
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default();
            let temporary = to.with_file_name(format!(".{name}.stack-{}", std::process::id()));
            let _ = fs::remove_file(&temporary);
            let meta = fs::symlink_metadata(&from)?;
            if meta.file_type().is_symlink() {
                let link = fs::read_link(&from)?;
                ensure!(
                    link.is_relative()
                        && to
                            .parent()
                            .map(|p| p.join(&link))
                            .is_some_and(|t| normal(&t).starts_with(root)),
                    "unsafe_package_member"
                );
                std::os::unix::fs::symlink(&link, &temporary)?;
            } else {
                fs::copy(&from, &temporary)?;
            }
            let existed = fs::symlink_metadata(&to).is_ok();
            fs::rename(&temporary, &to)?;
            if !existed {
                placed.push(to);
            }
        }
        Ok(())
    })();
    if result.is_err() {
        for path in placed {
            let _ = fs::remove_file(path);
        }
        return result;
    }
    if let Some(previous) = previous {
        let keep: BTreeSet<&String> = files.iter().collect();
        let others = owned_by_others(current, previous);
        for rel in &previous.files {
            if !keep.contains(rel) && !others.contains(rel) && safe_relative(rel) {
                let _ = fs::remove_file(root.join(rel));
            }
        }
    }
    Ok(())
}

/// `path` with `..` and `.` resolved by text (the target may not exist yet).
pub(super) fn normal(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for part in path.components() {
        match part {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other),
        }
    }
    out
}
