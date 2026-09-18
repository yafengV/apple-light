use std::{fs, process::Command};

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
