use super::*;

fn sample() -> Host {
    Host {
        id: String::new(),
        name: "Producción Ñuñoa".into(),
        description: "Bastión".into(),
        group: "AWS".into(),
        tags: vec![" prod ".into(), "PROD".into(), "aws".into()],
        host: "bastion.ejemplo.cl".into(),
        port: 2222,
        user: "deploy".into(),
        key: None,
        identity: None,
        jump: None,
        forwards: vec![
            Forward {
                id: String::new(),
                name: "Aurora".into(),
                kind: "local".into(),
                listen_port: 15432,
                target_host: "db.interna".into(),
                target_port: 5432,
                autostart: true,
                keep_alive: true,
            },
            Forward {
                id: String::new(),
                name: String::new(),
                kind: "dynamic".into(),
                listen_port: 18080,
                target_host: String::new(),
                target_port: 0,
                autostart: false,
                keep_alive: false,
            },
        ],
    }
}

#[test]
fn saves_hosts_with_ids_and_rejects_unsafe_values() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("store")).unwrap();
    let host = save(&store, sample()).unwrap();
    assert_eq!(host.id, "produccion-nunoa");
    assert_eq!(host.tags, vec!["prod".to_string(), "aws".to_string()]);
    assert_eq!(host.forwards[0].id, "aurora");
    assert_eq!(host.forwards[1].id, "dynamic-18080");
    let second = save(&store, sample()).unwrap();
    assert_eq!(second.id, "produccion-nunoa-2");
    assert_eq!(list(&store).unwrap().len(), 2);
    let mut bad = sample();
    bad.host = "-oProxyCommand=evil".into();
    assert!(save(&store, bad).is_err());
    let mut bad = sample();
    bad.user = "root;rm".into();
    assert!(save(&store, bad).is_err());
    let mut bad = sample();
    bad.forwards[0].listen_port = 80;
    assert_eq!(
        save(&store, bad).unwrap_err().to_string(),
        "invalid_forward"
    );
    let mut bad = sample();
    bad.key = Some("missing".into());
    assert_eq!(
        save(&store, bad).unwrap_err().to_string(),
        "unknown_ssh_key"
    );
    let mut bad = sample();
    bad.tags = vec!["a\u{1b}[31m".into()];
    assert_eq!(
        save(&store, bad).unwrap_err().to_string(),
        "invalid_ssh_host"
    );
    delete(&store, &second.id).unwrap();
    assert_eq!(list(&store).unwrap().len(), 1);
    assert_eq!(
        delete(&store, "nope").unwrap_err().to_string(),
        "unknown_ssh_host"
    );
}

#[test]
fn updating_several_hosts_writes_all_or_nothing() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("store")).unwrap();
    let first = save(&store, sample()).unwrap();
    let second = save(&store, sample()).unwrap();
    let before = std::fs::read(file(&store).unwrap()).unwrap();
    // The second change is invalid: the first must not reach the disk either.
    let mut a = first.clone();
    a.group = "Otro".into();
    let mut b = second.clone();
    b.host = "-oProxyCommand=evil".into();
    assert!(update_many(&store, vec![a.clone(), b]).is_err());
    assert_eq!(std::fs::read(file(&store).unwrap()).unwrap(), before);
    // An unknown host is refused too, and creating through this method is not possible.
    let mut ghost = first.clone();
    ghost.id = "nope".into();
    assert_eq!(
        update_many(&store, vec![a.clone(), ghost])
            .unwrap_err()
            .to_string(),
        "unknown_ssh_host"
    );
    assert_eq!(std::fs::read(file(&store).unwrap()).unwrap(), before);
    // All valid: both are written in one go.
    let mut b = second.clone();
    b.group = "Otro".into();
    let saved = update_many(&store, vec![a, b]).unwrap();
    assert_eq!(saved.len(), 2);
    assert!(list(&store).unwrap().iter().all(|h| h.group == "Otro"));
}

#[test]
fn jump_hosts_are_one_hop_and_cannot_be_deleted_while_used() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("store")).unwrap();
    let mut bastion = sample();
    bastion.name = "Bastión".into();
    bastion.forwards.clear();
    let bastion = save(&store, bastion).unwrap();
    let mut inner = sample();
    inner.name = "Interno".into();
    inner.host = "10.0.0.5".into();
    inner.port = 22;
    inner.jump = Some(bastion.id.clone());
    let inner = save(&store, inner).unwrap();
    // Jumping through a host that jumps, or through itself, is refused.
    let mut chain = sample();
    chain.name = "Cadena".into();
    chain.jump = Some(inner.id.clone());
    assert_eq!(
        save(&store, chain).unwrap_err().to_string(),
        "invalid_ssh_jump"
    );
    let mut own = inner.clone();
    own.jump = Some(inner.id.clone());
    assert_eq!(
        save(&store, own).unwrap_err().to_string(),
        "invalid_ssh_jump"
    );
    let mut missing = sample();
    missing.jump = Some("nope".into());
    assert_eq!(
        save(&store, missing).unwrap_err().to_string(),
        "invalid_ssh_jump"
    );
    // The bastion cannot get a jump while others use it, nor be deleted.
    let mut bastion_jumping = bastion.clone();
    bastion_jumping.jump = Some(inner.id.clone());
    assert!(save(&store, bastion_jumping).is_err());
    assert_eq!(
        delete(&store, &bastion.id).unwrap_err().to_string(),
        "ssh_host_in_use"
    );
    // The session reaches the target through a strictly verified jump; `%` and quotes stay inert.
    let args = session_args(&store, &inner).unwrap();
    let proxy = args
        .iter()
        .find(|a| a.starts_with("ProxyCommand="))
        .unwrap();
    assert!(proxy.starts_with("ProxyCommand='/usr/bin/ssh' '-o' 'StrictHostKeyChecking=yes'"));
    assert!(
        proxy.contains("'-p' '2222'")
            && proxy.ends_with("-W '[%h]:%p' '--' 'deploy@bastion.ejemplo.cl'")
    );
    assert!(!proxy.contains("BatchMode"));
    assert_eq!(
        &args[args.len() - 4..],
        ["-p", "22", "--", "deploy@10.0.0.5"]
    );
    let batch = connection_options(&store, &inner, true).unwrap();
    assert!(
        batch
            .iter()
            .any(|a| a.starts_with("ProxyCommand=") && a.contains("'BatchMode=yes'"))
    );
    delete(&store, &inner.id).unwrap();
    delete(&store, &bastion.id).unwrap();
}

#[test]
fn session_script_quotes_every_argument_and_binds_forwards_to_loopback() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::new(temp.path().join("store")).unwrap();
    let mut host = save(&store, sample()).unwrap();
    host.name = "O'Higgins $(whoami)".into();
    let script = session_script(&store, &host).unwrap();
    assert!(script.starts_with("#!/bin/zsh\nrm -f -- \"$0\"\n"));
    assert!(script.contains("'O'\\''Higgins $(whoami) — deploy@bastion.ejemplo.cl'"));
    assert!(script.contains("exec '/usr/bin/ssh' "));
    assert!(script.contains("'-p' '2222'") && script.contains("'--' 'deploy@bastion.ejemplo.cl'"));
    assert!(script.contains("'StrictHostKeyChecking=yes'"));
    let line = command_line(&store, &host).unwrap();
    assert!(
        line.starts_with("'/usr/bin/ssh' '-o' 'StrictHostKeyChecking=yes'")
            && line.contains("'UserKnownHostsFile=")
    );
    assert!(line.ends_with("'-p' '2222' '--' 'deploy@bastion.ejemplo.cl'"));
    assert_eq!(
        host.forwards[0].argument(),
        ("-L".into(), "127.0.0.1:15432:db.interna:5432".into())
    );
    assert_eq!(
        host.forwards[1].argument(),
        ("-D".into(), "127.0.0.1:18080".into())
    );
}

#[test]
fn dropped_forwards_wait_longer_each_time() {
    assert_eq!(backoff(1), 30);
    assert_eq!(backoff(3), 120);
    assert_eq!(backoff(9), 300);
}

#[test]
fn reads_key_pairs_from_known_hosts_lines() {
    let pairs = key_pairs(
        "# comment\n[h]:2222 ssh-ed25519 AAAA1\n|1|abc|def ssh-rsa BBBB\n@revoked h ssh-rsa CCCC\n",
    );
    assert_eq!(
        pairs,
        vec![
            ("ssh-ed25519".into(), "AAAA1".into()),
            ("ssh-rsa".into(), "BBBB".into())
        ]
    );
}
