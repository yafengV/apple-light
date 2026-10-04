//! Runs real native lifecycle hooks against a loopback Responses fixture.
use anyhow::{Result, ensure};
use codex_config::HookStateToml;
use codex_core_api::{Arg0DispatchPaths, EventMsg, ExecServerRuntimePaths, arg0_dispatch_or_else};
use serde_json::json;
use shipios_codex::{
    CodexSession, SessionHookSource, SessionOptions, SessionPermissions, session_hook_inventory,
};
use std::{collections::BTreeMap, path::Path};
use wiremock::{
    Mock, MockServer, ResponseTemplate,
    matchers::{method, path},
};

fn main() -> Result<()> {
    arg0_dispatch_or_else(run_main)
}

async fn execute(
    home: &Path,
    project: &Path,
    server: &MockServer,
    source: SessionHookSource,
    runtime_paths: ExecServerRuntimePaths,
    utility: bool,
) -> Result<()> {
    let options = SessionOptions {
        codex_home: home.to_owned(),
        project_root: project.to_owned(),
        additional_folders: Vec::new(),
        base_url: format!("{}/v1", server.uri()),
        model: "gpt-5.4".into(),
        api_key: None,
        read_only: false,
        permissions: SessionPermissions::default(),
        permission_profile_id: None,
        responses: Default::default(),
        web_search: Default::default(),
        mcp_servers: Vec::new(),
        hooks: vec![source],
        browser_bridge: None,
        automation_control: None,
        confetti: None,
        runtime_paths,
    };
    let session = if utility {
        CodexSession::start_text_generation(options).await?
    } else {
        CodexSession::start(options).await?
    };
    session
        .submit_text("Verify native lifecycle hooks".into())
        .await?;
    loop {
        match tokio::time::timeout(std::time::Duration::from_secs(15), session.next_event())
            .await??
        {
            EventMsg::TurnComplete(_) => break,
            EventMsg::Error(error) => anyhow::bail!(error.message),
            _ => {}
        }
    }
    session.shutdown().await?;
    Ok(())
}

async fn run_main(paths: Arg0DispatchPaths) -> Result<()> {
    let server = MockServer::start().await;
    let events = [
        json!({"type":"response.created","response":{"id":"hook-response"}}),
        json!({"type":"response.output_item.done","item":{"type":"message","role":"assistant",
          "id":"hook-message","content":[{"type":"output_text","text":"Hook fixture reply"}]}}),
        json!({"type":"response.completed","response":{"id":"hook-response","usage":{
          "input_tokens":0,"input_tokens_details":null,"output_tokens":0,"output_tokens_details":null,"total_tokens":0}}}),
    ];
    let response = events
        .iter()
        .map(|event| {
            format!(
                "event: {}\ndata: {event}\n\n",
                event["type"].as_str().unwrap()
            )
        })
        .collect::<String>();
    Mock::given(method("POST"))
        .and(path("/v1/responses"))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("content-type", "text/event-stream")
                .set_body_string(response),
        )
        .expect(4)
        .mount(&server)
        .await;
    let root = tempfile::tempdir()?;
    let project = root.path().join("Project");
    std::fs::create_dir_all(&project)?;
    let marker = root.path().join("lifecycle.txt");
    let prompt = root.path().join("prompt-input.json");
    let quote = |path: &Path| format!("'{}'", path.display().to_string().replace('\'', "'\\''"));
    let command = |event: &str| format!("printf '%s\\n' {event} >> {}", quote(&marker));
    let mut source = SessionHookSource { id: "native-lifecycle".into(), states: BTreeMap::new(),
        configuration: json!({"hooks":{
          "SessionStart":[{"hooks":[{"type":"command","command":format!("{}; printf '%s\\n' NATIVE-START-CONTEXT",command("SessionStart"))}]}],
          "UserPromptSubmit":[{"hooks":[{"type":"command","command":format!("{}; /bin/cat > {}; printf '%s\\n' NATIVE-PROMPT-CONTEXT",command("UserPromptSubmit"),quote(&prompt))}]}],
          "Stop":[{"hooks":[{"type":"command","command":command("Stop")}]}],
          "SessionEnd":[{"hooks":[{"type":"command","command":command("SessionEnd")}]}]
        }}).to_string() };
    let runtime = ExecServerRuntimePaths::from_optional_paths(
        paths.codex_self_exe,
        paths.codex_linux_sandbox_exe,
    )?;
    let untrusted_home = root.path().join("Untrusted");
    execute(
        &untrusted_home,
        &project,
        &server,
        source.clone(),
        runtime.clone(),
        false,
    )
    .await?;
    ensure!(!marker.exists(), "untrusted hooks executed");
    let inventory = session_hook_inventory(&untrusted_home, &[source.clone()])?;
    ensure!(
        inventory.hooks.len() == 4,
        "not all native lifecycle handlers were discovered"
    );
    for hook in inventory.hooks {
        source.states.insert(
            hook.key,
            HookStateToml {
                enabled: Some(true),
                trusted_hash: Some(hook.current_hash),
            },
        );
    }
    execute(
        &root.path().join("Trusted"),
        &project,
        &server,
        source.clone(),
        runtime.clone(),
        false,
    )
    .await?;
    let executed = std::fs::read_to_string(&marker)?;
    ensure!(
        executed.lines().collect::<Vec<_>>()
            == ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"],
        "native lifecycle order changed: {executed}"
    );
    let payload: serde_json::Value = serde_json::from_slice(&std::fs::read(&prompt)?)?;
    ensure!(
        payload["hook_event_name"] == "UserPromptSubmit"
            && payload["prompt"] == "Verify native lifecycle hooks",
        "the command did not receive the actual native prompt event"
    );
    source.configuration = source
        .configuration
        .replace("NATIVE-START-CONTEXT", "MODIFIED-START-CONTEXT");
    execute(
        &root.path().join("Modified"),
        &project,
        &server,
        source.clone(),
        runtime.clone(),
        false,
    )
    .await?;
    let modified = std::fs::read_to_string(&marker)?;
    ensure!(
        modified
            .lines()
            .filter(|line| *line == "SessionStart")
            .count()
            == 1,
        "a modified definition executed without review"
    );
    execute(
        &root.path().join("Utility"),
        &project,
        &server,
        source,
        runtime,
        true,
    )
    .await?;
    ensure!(
        std::fs::read_to_string(&marker)? == modified,
        "utility generation executed hooks"
    );
    let requests = server.received_requests().await.unwrap();
    ensure!(requests.len() == 4, "unexpected number of model requests");
    let bodies: Vec<_> = requests
        .iter()
        .map(|request| String::from_utf8_lossy(&request.body))
        .collect();
    ensure!(
        !bodies[0].contains("NATIVE-START-CONTEXT"),
        "untrusted context reached the model"
    );
    ensure!(
        bodies[1].contains("NATIVE-START-CONTEXT") && bodies[1].contains("NATIVE-PROMPT-CONTEXT"),
        "actual hook output did not enter developer context"
    );
    ensure!(
        !bodies[2].contains("MODIFIED-START-CONTEXT")
            && bodies[2].contains("NATIVE-PROMPT-CONTEXT"),
        "modified context was not isolated from still-trusted handlers"
    );
    ensure!(
        !bodies[3].contains("NATIVE-PROMPT-CONTEXT"),
        "utility generation inherited hook context"
    );
    server.verify().await;
    println!(
        "PASS: native trust, real lifecycle commands/input/context, changed-definition skip, and utility isolation"
    );
    Ok(())
}
