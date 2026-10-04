use serde_json::{Value, json};
use std::{
    io::{BufRead, BufReader, Write},
    process::{Child, ChildStdin, Command, Stdio},
    sync::mpsc::{self, Receiver},
    time::{Duration, Instant},
};

struct Client {
    child: Child,
    input: Option<ChildStdin>,
    messages: Receiver<Value>,
    next_id: u64,
}

impl Client {
    fn launch(data: &std::path::Path, project: &std::path::Path) -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_shipios-agent"))
            .args([
                "--data-dir",
                data.to_str().unwrap(),
                "--project",
                project.to_str().unwrap(),
                "serve",
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let input = child.stdin.take();
        let output = child.stdout.take().unwrap();
        let (sender, messages) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(output).lines() {
                let Ok(line) = line else { break };
                let Ok(value) = serde_json::from_str(&line) else {
                    break;
                };
                if sender.send(value).is_err() {
                    break;
                }
            }
        });
        Self {
            child,
            input,
            messages,
            next_id: 0,
        }
    }

    fn request(&mut self, method: &str, params: Value) -> Value {
        self.next_id += 1;
        writeln!(
            self.input.as_mut().unwrap(),
            "{}",
            json!({
                "jsonrpc":"2.0", "id":self.next_id, "method":method, "params":params
            })
        )
        .unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let value = self
                .messages
                .recv_timeout(deadline.saturating_duration_since(Instant::now()))
                .expect("Agent RPC must return before timeout");
            if value["id"] == self.next_id {
                return value;
            }
        }
    }

    fn finish(&mut self) {
        self.input.take();
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(status) = self.child.try_wait().unwrap() {
                assert!(status.success());
                return;
            }
            assert!(
                Instant::now() < deadline,
                "Agent did not exit after stdin EOF"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[test]
fn native_hook_inventory_round_trips_trust_and_recovers_from_invalid_sources() {
    let root = tempfile::tempdir().unwrap();
    let project = root.path().join("Project");
    let personal = project.join(".codex");
    std::fs::create_dir_all(&personal).unwrap();
    let marker = root.path().join("must-not-run");
    let config = json!({"hooks":{"SessionStart":[{"hooks":[{
        "type":"command", "command":format!("touch '{}'", marker.display()), "async":true,
        "timeout":4,"statusMessage":"Loading fixture","additionalContextLimit":300
    }]}]}})
    .to_string();
    // Listing app-supplied definitions must not import project-local hooks.
    std::fs::write(personal.join("hooks.json"), &config).unwrap();
    let data = root.path().join("Data");
    let mut client = Client::launch(&data, &project);
    assert_eq!(
        client.request("initialize", json!({"protocolVersion":1}))["result"]["protocolVersion"],
        1
    );
    let mut source = json!({"id":"fixture","configuration":config});
    let first = client.request("codex.hooks.list", json!({"sources":[source.clone()]}));
    assert!(first.get("error").is_none(), "{first}");
    let hooks = first["result"]["hooks"].as_array().unwrap();
    assert_eq!(hooks.len(), 1);
    let hook = &hooks[0];
    assert_eq!(hook["sourceId"], "fixture");
    assert_eq!(hook["trustStatus"], "untrusted");
    assert_eq!(hook["enabled"], true);
    assert_eq!(hook["timeoutSec"], 4);
    assert_eq!(hook["definition"]["handler"]["async"], true);
    assert_eq!(hook["additionalContextLimit"], 300);
    assert_eq!(hook["statusMessage"], "Loading fixture");
    let key = hook["key"].as_str().unwrap().to_owned();
    let hash = hook["currentHash"].as_str().unwrap().to_owned();
    assert_eq!(key, "session_start:0:0");
    assert!(hash.starts_with("sha256:"));
    source["states"] = json!({key.clone():{"enabled":true,"trusted_hash":hash}});
    let trusted = client.request("codex.hooks.list", json!({"sources":[source.clone()]}));
    assert_eq!(trusted["result"]["hooks"][0]["trustStatus"], "trusted");
    source["configuration"] = Value::String(config.replace("touch", "echo"));
    let changed = client.request("codex.hooks.list", json!({"sources":[source.clone()]}));
    assert_eq!(changed["result"]["hooks"][0]["trustStatus"], "modified");
    source["states"][&key]["enabled"] = json!(false);
    let disabled = client.request("codex.hooks.list", json!({"sources":[source.clone()]}));
    assert_eq!(disabled["result"]["hooks"][0]["enabled"], false);
    source["id"] = json!("../outside");
    assert!(
        client
            .request("codex.hooks.list", json!({"sources":[source]}))
            .get("error")
            .is_some()
    );
    assert_eq!(
        client.request("codex.hooks.list", json!({"sources":[],"bypassTrust":true}))["error"]["code"],
        -32602
    );
    let empty = client.request("codex.hooks.list", json!({"sources":[]}));
    assert_eq!(empty["result"]["hooks"], json!([]));
    client.finish();
    assert!(!marker.exists());
    assert!(!data.join("Codex/HookInventory/HookBindings").exists());
    assert_eq!(
        std::fs::read_to_string(personal.join("hooks.json")).unwrap(),
        config
    );
}
