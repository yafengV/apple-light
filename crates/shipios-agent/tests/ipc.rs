use serde_json::{Value, json};
use std::{
    fs,
    io::Write,
    process::{Command, Stdio},
};

#[test]
fn sigterm_exits_even_when_client_keeps_stdin_open() {
    use std::io::{BufRead, BufReader};
    use std::time::{Duration, Instant};
    let temp = tempfile::tempdir().unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_shipios-agent"))
        .args(["--data-dir", temp.path().to_str().unwrap(), "serve"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    writeln!(
        input,
        "{}",
        json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}})
    )
    .unwrap();
    let stdout = child.stdout.take().unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut line = String::new();
        let _ = BufReader::new(stdout).read_line(&mut line);
        let _ = tx.send(line);
    });
    if rx.recv_timeout(Duration::from_secs(5)).is_err() {
        let _ = child.kill();
        let _ = child.wait();
        panic!("handshake timed out");
    }
    assert!(
        Command::new("/bin/kill")
            .args(["-TERM", &child.id().to_string()])
            .status()
            .unwrap()
            .success()
    );
    let started = Instant::now();
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            assert!(status.success());
            break;
        }
        if started.elapsed() > Duration::from_secs(3) {
            let _ = child.kill();
            let _ = child.wait();
            panic!("agent waited indefinitely for stdin EOF");
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    drop(input);
}

#[test]
fn stdio_frames_are_valid_and_personal_codex_settings_are_ignored() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().join("home");
    let project = temp.path().join("project");
    let data = temp.path().join("shipios");
    fs::create_dir_all(home.join(".codex")).unwrap();
    fs::create_dir_all(project.join(".codex")).unwrap();
    let poison = "model = 'personal-codex-must-not-load'";
    fs::write(home.join(".codex/config.toml"), poison).unwrap();
    fs::write(project.join(".codex/config.toml"), poison).unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_shipios-agent"))
        .args([
            "--project",
            project.to_str().unwrap(),
            "--data-dir",
            data.to_str().unwrap(),
            "serve",
        ])
        .env("HOME", &home)
        .env("CODEX_HOME", home.join(".codex"))
        .env("OPENAI_API_KEY", "sentinel-not-a-real-key")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    writeln!(input, "invalid json").unwrap();
    for value in [
        json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}),
        json!({"jsonrpc":"2.0","id":2,"method":"config.get"}),
        json!({"jsonrpc":"2.0","id":3,"method":"run.list"}),
        json!({"jsonrpc":"2.0","id":4,"method":"run.start","params":{"kind":"coding","prompt":"not supported"}}),
        json!({"jsonrpc":"2.0","id":5,"method":"run.start","params":{"kind":"build","container":"../outside.xcodeproj","scheme":"Bad"}}),
    ] {
        writeln!(input, "{value}").unwrap();
    }
    drop(input);
    let output = child.wait_with_output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let text = String::from_utf8(output.stdout).unwrap();
    assert!(!text.contains("sentinel-not-a-real-key"));
    assert!(!text.contains("personal-codex-must-not-load"));
    let frames: Vec<Value> = text
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(frames[0]["error"]["code"], -32700);
    assert_eq!(frames[1]["result"]["capabilities"]["codexEmbedded"], false);
    assert_eq!(frames[2]["result"]["model"], Value::Null);
    assert_eq!(frames[3]["result"], json!([]));
    assert_eq!(frames[4]["error"]["code"], -32602);
    assert_eq!(frames[5]["error"]["code"], -32010);
    assert_eq!(
        fs::read_to_string(home.join(".codex/config.toml")).unwrap(),
        poison
    );
    assert_eq!(fs::read_dir(home.join(".codex")).unwrap().count(), 1);
}
