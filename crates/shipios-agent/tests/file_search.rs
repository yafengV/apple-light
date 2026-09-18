use std::{fs, process::Command};

#[test]
fn session_reuses_index_handles_query_changes_and_exits_on_eof() {
    use std::{
        io::{BufRead, BufReader, Write},
        process::Stdio,
        sync::mpsc,
        time::{Duration, Instant},
    };
    let root = tempfile::tempdir().unwrap();
    fs::write(root.path().join("AlphaBeta.swift"), "").unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_shipios-agent"))
        .arg("--project")
        .arg(root.path())
        .arg("search-files-session")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    let output = child.stdout.take().unwrap();
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(output).lines().map_while(Result::ok) {
            if sender
                .send(serde_json::from_str::<serde_json::Value>(&line).unwrap())
                .is_err()
            {
                break;
            }
        }
    });
    let receive = |id: u64| loop {
        let update = receiver.recv_timeout(Duration::from_secs(5)).unwrap();
        if update["id"] == id && update["complete"] == true {
            break update;
        }
    };
    writeln!(input, "{}", serde_json::json!({"id":1,"query":"ab"})).unwrap();
    assert_eq!(receive(1)["files"][0]["path"], "AlphaBeta.swift");
    // The original walk is complete: later queries reuse that snapshot, rather than rescanning.
    fs::write(root.path().join("NewAfterScan.swift"), "").unwrap();
    writeln!(input, "{}", serde_json::json!({"id":2,"query":"AfterScan"})).unwrap();
    assert!(receive(2)["files"].as_array().unwrap().is_empty());
    writeln!(
        input,
        "{}\n{}",
        serde_json::json!({"id":3,"query":"missing"}),
        serde_json::json!({"id":4,"query":"beta"})
    )
    .unwrap();
    assert_eq!(receive(4)["files"][0]["path"], "AlphaBeta.swift");
    writeln!(input, "{}", serde_json::json!({"id":5,"query":" "})).unwrap();
    assert!(receive(5)["files"].as_array().unwrap().is_empty());
    drop(input);
    let began = Instant::now();
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            assert!(status.success());
            break;
        }
        if began.elapsed() > Duration::from_secs(3) {
            let _ = child.kill();
            panic!("Session did not exit on EOF");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn file_search_is_read_only_and_does_not_load_agent_configuration() {
    let root = tempfile::tempdir().unwrap();
    let project = root.path().join("Project with spaces");
    fs::create_dir(&project).unwrap();
    fs::write(project.join("CommandPaletteView.swift"), "fixture").unwrap();
    let data = root.path().join("agent-state-must-not-exist");
    let output = Command::new(env!("CARGO_BIN_EXE_shipios-agent"))
        .arg("--data-dir")
        .arg(&data)
        .arg("--project")
        .arg(&project)
        .args(["search-files", "--query", "CPV"])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let results: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(results[0]["path"], "CommandPaletteView.swift");
    assert_eq!(results[0]["isDirectory"], false);
    assert!(
        !data.exists(),
        "Search must not create agent config, authentication or database state"
    );
}
