//! P-43, the full run (slow and with network, opt-in): in a temporary store whose path has spaces
//! and a temporary HOME, PostgreSQL is installed from its official source, a project that declares
//! PostGIS shows what is missing and is resolved from it (PostGIS, GEOS, PROJ and JSON-C built from
//! their official origins), pgvector is installed and activated, and removing an extension in use is
//! refused. Never the user's PostgreSQL, databases or projects.
//!
//! ```sh
//! BUTAKE_P43_LIVE=1 cargo test --test extensions_live -- --ignored --nocapture
//! ```
//! `BUTAKE_P43_DIR` keeps the run's folder (a re-run skips the PostgreSQL build); `BUTAKE_P43_REPORT`
//! is where the summary is written.
use serde_json::{Value, json};
use std::{
    io::Write,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};

struct Run {
    store: PathBuf,
    home: PathBuf,
}

impl Run {
    fn call(&self, request: Value) -> Value {
        let mut child = Command::new(env!("CARGO_BIN_EXE_butake-stack"))
            .env_clear()
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .env("HOME", &self.home)
            .env("BUTAKE_STACK_HOME", &self.store)
            .env("BUTAKE_DEVTOOLS_HOME", &self.home)
            .env("BUTAKE_STACK_DEBUG", "1")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(request.to_string().as_bytes())
            .unwrap();
        let out = child.wait_with_output().unwrap();
        serde_json::from_slice(&out.stdout).unwrap()
    }

    fn ok(&self, request: Value) -> Value {
        let answer = self.call(request.clone());
        assert_eq!(answer["ok"], true, "{request} -> {answer}");
        answer["value"].clone()
    }

    fn engine(&self, version: &str) -> PathBuf {
        self.store.join("runtimes/postgres").join(version)
    }

    /// `psql` as the superuser (its password, as Stack keeps it, in the environment).
    fn sql(&self, version: &str, port: u16, database: &str, sql: &str) -> String {
        let password =
            std::fs::read_to_string(self.store.join("config/postgres/superuser.password")).unwrap();
        let out = Command::new(self.engine(version).join("bin/psql"))
            .env_clear()
            .env("PGPASSWORD", password.trim())
            .args([
                "-h",
                "127.0.0.1",
                "-p",
                &port.to_string(),
                "-U",
                "postgres",
                "-d",
                database,
            ])
            .args(["-v", "ON_ERROR_STOP=1", "-tA", "-c", sql])
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{sql}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    }
}

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

struct Server(Child);
impl Drop for Server {
    /// Stopped by its own PID (fast shutdown), never by name.
    fn drop(&mut self) {
        // SAFETY: `kill` takes two integers and touches no memory; the PID is this test's own child,
        // not yet reaped (it is waited for right after), so it cannot be another process.
        unsafe {
            libc::kill(self.0.id() as i32, libc::SIGINT);
        }
        let _ = self.0.wait();
    }
}

#[test]
#[ignore]
fn postgis_and_pgvector_from_their_official_origins() {
    if std::env::var_os("BUTAKE_P43_LIVE").is_none() {
        eprintln!("BUTAKE_P43_LIVE no está definida: corrida completa omitida");
        return;
    }
    let base = std::env::var_os("BUTAKE_P43_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| tempfile::tempdir().unwrap().keep());
    // Like `~/Library/Application Support/Stack`: spaces in the store's path.
    let run = Run {
        store: base.join("Application Support/Stack P43"),
        home: base.join("home"),
    };
    std::fs::create_dir_all(&run.home).unwrap();
    let version = std::env::var("BUTAKE_P43_POSTGRES").unwrap_or_else(|_| "18.7".into());
    let mut report = json!({"store": run.store, "postgres": version});
    let started = Instant::now();

    if !run.engine(&version).join("bin/postgres").exists() {
        let t = Instant::now();
        run.ok(json!({"method": "installTool", "tool": "postgres", "version": version, "confirmed": true}));
        report["postgresBuildSeconds"] = json!(t.elapsed().as_secs());
    }
    let port = free_port();
    run.ok(json!({"method": "setEngine", "engine": "postgres", "enabled": true, "version": version, "port": port}));

    // A cluster like the ones Stack creates (scram, superuser password in config/postgres).
    let data = run.store.join("data/postgres");
    let password_file = run.store.join("config/postgres/superuser.password");
    if !data.join("PG_VERSION").exists() {
        std::fs::create_dir_all(password_file.parent().unwrap()).unwrap();
        let mut bytes = [0u8; 24];
        std::io::Read::read_exact(
            &mut std::fs::File::open("/dev/urandom").unwrap(),
            &mut bytes,
        )
        .unwrap();
        let password: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
        std::fs::write(&password_file, &password).unwrap();
        let pwfile = base.join("pw");
        std::fs::write(&pwfile, &password).unwrap();
        std::fs::create_dir_all(&data).unwrap();
        let status = Command::new(run.engine(&version).join("bin/initdb"))
            .env_clear()
            .args([
                "--encoding=UTF8",
                "--locale=C",
                "--auth-local=scram-sha-256",
                "--auth-host=scram-sha-256",
                "--username=postgres",
            ])
            .arg(format!("--pwfile={}", pwfile.display()))
            .arg("-D")
            .arg(&data)
            .stdout(Stdio::null())
            .status()
            .unwrap();
        std::fs::remove_file(&pwfile).unwrap();
        assert!(status.success());
    }
    let socket = PathBuf::from(format!("/private/tmp/p43-{}", std::process::id()));
    std::fs::create_dir_all(&socket).unwrap();
    let server = Server(
        Command::new(run.engine(&version).join("bin/postgres"))
            .env_clear()
            .arg("-D")
            .arg(&data)
            .args(["-p", &port.to_string(), "-h", "127.0.0.1", "-k"])
            .arg(&socket)
            .stdout(Stdio::null())
            .stderr(std::fs::File::create(base.join("postgres.log")).unwrap())
            .spawn()
            .unwrap(),
    );
    let ready = (0..100).any(|_| {
        std::thread::sleep(Duration::from_millis(200));
        Command::new(run.engine(&version).join("bin/pg_isready"))
            .env_clear()
            .args(["-h", "127.0.0.1", "-p", &port.to_string()])
            .stdout(Stdio::null())
            .status()
            .is_ok_and(|s| s.success())
    });
    assert!(ready, "PostgreSQL de prueba no arrancó");

    // A project that declares PostGIS for its database, which exists but has none.
    let folder = base.join("projects/geo");
    std::fs::create_dir_all(&folder).unwrap();
    let created =
        run.call(json!({"method": "createDatabase", "engine": "postgres", "name": "geo_p43"}));
    assert!(
        created["ok"] == true
            || run.sql(
                &version,
                port,
                "postgres",
                "SELECT 1 FROM pg_database WHERE datname='geo_p43'"
            ) == "1"
    );
    let project = json!({"id": "geo-p43", "name": "Geo P43", "path": folder, "domains": ["geo-p43.test"],
        "https": false, "kind": "static", "runtime": {}, "docroot": ".", "services": ["postgres"],
        "databases": [{"name": "geo_p43", "extensions": ["postgis"]}], "processes": []});
    run.ok(json!({"method": "saveProject", "project": project, "actor": "p43"}));
    let before = run.ok(json!({"method": "projectExtensions", "id": "geo-p43"}));
    report["projectBefore"] = before.clone();
    let postgis_installed = run
        .engine(&version)
        .join("butake-extensions.json")
        .is_file()
        && std::fs::read_to_string(run.engine(&version).join("butake-extensions.json"))
            .unwrap()
            .contains("\"postgis\"");
    if !postgis_installed {
        assert_eq!(before[0]["problem"], "notInstalled", "{before}");
        assert_eq!(before[0]["catalog"], "postgis");
        assert_eq!(
            run.ok(json!({"method": "installSteps", "tool": "extension-project-geo-p43"})),
            json!([
                "downloadSource",
                "verifySum",
                "buildDependencies",
                "build",
                "install",
                "activate"
            ])
        );
    }
    // «Resolver»: installs PostGIS (and what it needs) and activates it in the database.
    let t = Instant::now();
    let after =
        run.call(json!({"method": "resolveProjectExtensions", "id": "geo-p43", "confirmed": true}));
    report["resolveSeconds"] = json!(t.elapsed().as_secs());
    let _ = std::fs::copy(
        run.store.join("logs/install-extension.log"),
        base.join("install-postgis.log"),
    );
    assert_eq!(after["ok"], true, "{after}");
    assert_eq!(after["value"], json!([]), "{after}");
    report["postgisVersion"] =
        json!(run.sql(&version, port, "geo_p43", "SELECT PostGIS_Full_Version()"));
    report["postgisTransform"] = json!(run.sql(&version, port, "geo_p43",
        "SELECT ST_AsText(ST_SnapToGrid(ST_Transform(ST_SetSRID(ST_Point(-70.65, -33.45), 4326), 3857), 1))"));
    report["postgisGeoJSON"] = json!(run.sql(
        &version,
        port,
        "geo_p43",
        "SELECT ST_AsText(ST_GeomFromGeoJSON('{\"type\":\"Point\",\"coordinates\":[1,2]}'))"
    ));
    assert!(
        report["postgisVersion"]
            .as_str()
            .unwrap()
            .contains("POSTGIS=\"3.7.0")
    );

    // pgvector: installed in the engine, activated in the database, and used.
    let t = Instant::now();
    run.ok(json!({"method": "installExtension", "component": "postgres", "id": "pgvector", "confirmed": true}));
    report["pgvectorSeconds"] = json!(t.elapsed().as_secs());
    run.ok(json!({"method": "activateExtension", "database": "geo_p43", "name": "vector", "confirmed": true}));
    report["pgvectorDistance"] = json!(run.sql(
        &version,
        port,
        "geo_p43",
        "SELECT '[1,2,3]'::vector <-> '[1,2,5]'::vector"
    ));
    assert_eq!(report["pgvectorDistance"], "2");

    // Both levels as the app reads them.
    let catalog = run.ok(json!({"method": "extensionCatalog", "component": "postgres"}));
    for id in ["postgis", "pgvector"] {
        let entry = catalog["extensions"]
            .as_array()
            .unwrap()
            .iter()
            .find(|e| e["id"] == id)
            .unwrap();
        assert!(entry["installed"].is_string(), "{entry}");
    }
    let active = run.ok(json!({"method": "databaseExtensions", "database": "geo_p43"}));
    report["active"] = active["active"].clone();

    // Removing is refused while a database uses it, naming it.
    let refused = run.call(json!({"method": "removeExtension", "component": "postgres", "id": "postgis", "confirmed": true}));
    assert_eq!(refused["error"]["code"], "extension_in_use", "{refused}");
    assert_eq!(refused["error"]["detail"], "geo_p43");
    report["removeRefused"] = refused["error"].clone();
    // Deactivating says what would be lost first.
    run.sql(
        &version,
        port,
        "geo_p43",
        "CREATE TABLE IF NOT EXISTS lugares (id int, punto geometry(Point, 4326))",
    );
    let dependents =
        run.ok(json!({"method": "extensionDependents", "database": "geo_p43", "name": "postgis"}));
    assert_eq!(dependents, json!(["column punto of table lugares"]));
    report["postgisDependents"] = dependents;
    let refused = run.call(json!({"method": "deactivateExtension", "database": "geo_p43", "name": "postgis", "confirmed": true}));
    assert_eq!(refused["error"]["code"], "extension_has_dependents");
    // pgvector, unused: deactivated, then removed from the engine.
    run.ok(json!({"method": "deactivateExtension", "database": "geo_p43", "name": "vector", "confirmed": true}));
    run.ok(json!({"method": "removeExtension", "component": "postgres", "id": "pgvector", "confirmed": true}));
    let catalog = run.ok(json!({"method": "extensionCatalog", "component": "postgres"}));
    let pgvector = catalog["extensions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|e| e["id"] == "pgvector")
        .unwrap();
    assert!(pgvector["installed"].is_null());
    // And installed again, so the state below shows both.
    run.ok(json!({"method": "installExtension", "component": "postgres", "id": "pgvector", "confirmed": true}));
    report["state"] = run.ok(json!({"method": "extensionState"}));
    report["installed"] = json!(
        std::fs::read_to_string(run.engine(&version).join("butake-extensions.json"))
            .unwrap()
            .len()
    );
    report["totalSeconds"] = json!(started.elapsed().as_secs());
    drop(server);
    let _ = std::fs::remove_dir_all(&socket);
    let text = serde_json::to_string_pretty(&report).unwrap();
    println!("{text}");
    if let Some(path) = std::env::var_os("BUTAKE_P43_REPORT") {
        std::fs::write(Path::new(&path), text).unwrap();
    }
}
