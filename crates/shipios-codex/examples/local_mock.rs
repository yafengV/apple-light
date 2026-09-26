use anyhow::Result;
use codex_core_api::{Arg0DispatchPaths, EventMsg, ExecServerRuntimePaths, arg0_dispatch_or_else};
use serde_json::json;
use shipios_codex::{CodexSession, SessionOptions, SessionPermissions};
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

fn main() -> Result<()> {
    arg0_dispatch_or_else(run_main)
}

async fn run_main(paths: Arg0DispatchPaths) -> Result<()> {
    let server = MockServer::start().await;
    let response = [
        json!({"type": "response.created", "response": {"id": "resp-1"}}),
        json!({"type": "response.output_item.done", "item": {
            "type": "message", "role": "assistant", "id": "msg-1",
            "content": [{"type": "output_text", "text": "ShipiOS adapter reply"}]
        }}),
        json!({"type": "response.completed", "response": {
            "id": "resp-1", "usage": {
                "input_tokens": 0, "input_tokens_details": null,
                "output_tokens": 0, "output_tokens_details": null, "total_tokens": 0
            }
        }}),
    ]
    .into_iter()
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
        .expect(1)
        .mount(&server)
        .await;

    let root = tempfile::tempdir()?;
    let home = root.path().join("Agent");
    let project = root.path().join("Project");
    std::fs::create_dir_all(&project)?;
    let token = "adapter-test-token";
    let runtime_paths = ExecServerRuntimePaths::from_optional_paths(
        paths.codex_self_exe,
        paths.codex_linux_sandbox_exe,
    )?;
    let session = CodexSession::start(SessionOptions {
        codex_home: home.clone(),
        project_root: project.clone(),
        base_url: format!("{}/v1", server.uri()),
        model: "gpt-5.2".to_owned(),
        api_key: Some(token.to_owned()),
        read_only: false,
        permissions: SessionPermissions::default(),
        responses: Default::default(),
        web_search: Default::default(),
        mcp_servers: Vec::new(),
        runtime_paths: runtime_paths.clone(),
    })
    .await?;
    let duplicate = CodexSession::start(SessionOptions {
        codex_home: home.clone(),
        project_root: project,
        base_url: format!("{}/v1", server.uri()),
        model: "gpt-5.2".to_owned(),
        api_key: None,
        read_only: false,
        permissions: SessionPermissions::default(),
        responses: Default::default(),
        web_search: Default::default(),
        mcp_servers: Vec::new(),
        runtime_paths,
    })
    .await;
    assert!(
        duplicate
            .err()
            .expect("duplicate home must fail")
            .to_string()
            .contains("already in use")
    );
    let rollout = session.rollout_path().expect("local rollout path");
    assert!(rollout.starts_with(home.canonicalize()?));
    let turn_id = session.submit_text("Test the adapter".to_owned()).await?;
    assert!(!turn_id.is_empty());
    let mut message = None;
    loop {
        let event = tokio::time::timeout(std::time::Duration::from_secs(10), session.next_event())
            .await??;
        match event {
            EventMsg::AgentMessage(reply) => message = Some(reply.message),
            EventMsg::TurnComplete(complete) => {
                assert_eq!(complete.last_agent_message, message);
                break;
            }
            EventMsg::Error(error) => anyhow::bail!(error.message),
            _ => {}
        }
    }
    assert_eq!(message.as_deref(), Some("ShipiOS adapter reply"));
    session.shutdown().await?;
    assert!(rollout.is_file());
    assert!(!home.join("auth.json").exists());
    assert!(!std::fs::read_to_string(rollout)?.contains(token));
    let requests = server.received_requests().await.expect("mock requests");
    assert_eq!(requests.len(), 1);
    let authorization = requests[0]
        .headers
        .get("authorization")
        .and_then(|header| header.to_str().ok());
    assert_eq!(authorization, Some("Bearer adapter-test-token"));
    server.verify().await;
    println!("ShipiOS Codex adapter round trip passed");
    Ok(())
}
