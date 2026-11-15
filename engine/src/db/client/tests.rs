use super::*;

fn sample(kind: &str) -> Connection {
    Connection {
        id: "remota".into(),
        name: "Remota".into(),
        kind: kind.into(),
        host: "db.example.com".into(),
        port: 3306,
        user: "app".into(),
        database: "app".into(),
        path: None,
        tls: "prefer".into(),
        ssh: None,
        builtin: false,
        has_password: true,
        stack_password: false,
        production: false,
        read_only: false,
    }
}

#[test]
fn connections_are_validated_and_saved_without_passwords() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("store")).unwrap();
    let mut c = sample("mysql");
    save(&store, c.clone()).unwrap();
    let text = std::fs::read_to_string(store.directory("config").unwrap().join("connections.json"))
        .unwrap();
    assert!(!text.to_lowercase().contains("password\":\""));
    assert_eq!(list(&store).unwrap().len(), 1);
    for bad in ["-oProxyCommand=x", "a b", "a;b", ""] {
        c.host = bad.into();
        assert!(c.clone().validate().is_err(), "{bad}");
    }
    c.host = "db.example.com".into();
    c.id = "stack-mysql".into();
    assert!(c.validate().is_err(), "built-in ids are reserved");
    let mut s = sample("postgres");
    s.ssh = Some(Ssh {
        host: "bastion".into(),
        port: 22,
        user: "-oProxy".into(),
        identity: None,
        key: None,
    });
    assert!(s.validate().is_err());
    s.ssh = Some(Ssh {
        host: "bastion".into(),
        port: 22,
        user: "deploy".into(),
        identity: Some("/etc/passwd".into()),
        key: None,
    });
    assert!(s.validate().is_err(), "keys only from ~/.ssh");
    delete(&store, "remota").unwrap();
    assert!(list(&store).unwrap().is_empty());
}

#[test]
fn marked_csv_blocks_become_results() {
    let out = format!(
        "id,name\n1,{NULL_MARK}\n2,\"\"\n{RESULT_MARK} 2\n{RESULT_MARK} 5\nx\n{RESULT_MARK} 0\n"
    );
    let statements = vec!["select".to_string(), "update".into(), "select none".into()];
    let results = split_marked(&out, &statements, 10);
    assert_eq!(results.len(), 3);
    assert_eq!(
        results[0].rows,
        vec![
            vec![Some("1".into()), None],
            vec![Some("2".into()), Some(String::new())]
        ]
    );
    assert_eq!(results[1].affected, Some(5));
    assert!(results[1].columns.is_empty());
    assert_eq!(results[2].columns, vec!["x"]);
    assert_eq!(results[2].statement, "select none");
}

#[test]
fn redis_console_reads_freely_and_asks_before_writes() {
    assert!(
        redis_read_only("GET key")
            && redis_read_only("config get maxmemory")
            && redis_read_only("client list")
    );
    assert!(
        !redis_read_only("SET a b")
            && !redis_read_only("flushall")
            && !redis_read_only("config set x y")
            && !redis_read_only("client kill id 3")
    );
}
