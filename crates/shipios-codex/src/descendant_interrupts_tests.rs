use super::*;
use codex_protocol::protocol::{AgentStatus, SubAgentSource};
use std::time::Duration;
use wiremock::matchers::{body_string_contains, method};
use wiremock::{Mock, MockServer, ResponseTemplate};

fn run_native_test(work: impl Future<Output = Result<()>> + Send + 'static) -> Result<()> {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .thread_stack_size(16 * 1024 * 1024)
        .build()?;
    runtime.block_on(async { tokio::spawn(work).await? })
}

async fn server() -> MockServer {
    let server = MockServer::start().await;
    let item = json!({"type":"message","id":"reply","role":"assistant",
        "content":[{"type":"output_text","text":"Completed native child"}]});
    let response = json!({"id":"response","object":"response","status":"completed",
        "output":[item],"usage":{"input_tokens":10,"output_tokens":4,"total_tokens":14}});
    let events = [
        json!({"type":"response.created","response":{"id":"response","status":"in_progress","output":[]}}),
        json!({"type":"response.output_item.done","item":item}),
        json!({"type":"response.completed","response":response}),
    ];
    let body = events
        .iter()
        .map(|event| {
            format!(
                "event: {}\ndata: {}\n\n",
                event["type"].as_str().unwrap(),
                event
            )
        })
        .collect::<String>();
    Mock::given(method("POST"))
        .and(body_string_contains("complete-child"))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("Content-Type", "text/event-stream")
                .set_body_string(body),
        )
        .with_priority(1)
        .mount(&server)
        .await;
    Mock::given(method("POST"))
        .respond_with(ResponseTemplate::new(200).set_delay(Duration::from_secs(60)))
        .with_priority(10)
        .mount(&server)
        .await;
    server
}

async fn session(root: &std::path::Path, server: &MockServer, name: &str) -> Result<CodexSession> {
    let project = root.join("Project");
    std::fs::create_dir_all(&project)?;
    CodexSession::start(SessionOptions {
        codex_home: root.join(name),
        project_root: project,
        additional_folders: Vec::new(),
        base_url: format!("{}/v1", server.uri()),
        model: "gpt-5.4".to_owned(),
        api_key: Some("native-child-fixture-key".to_owned()),
        read_only: false,
        permissions: SessionPermissions::default(),
        permission_profile_id: None,
        responses: SessionResponsePreferences::default(),
        web_search: SessionWebSearch::default(),
        mcp_servers: Vec::new(),
        hooks: Vec::new(),
        browser_bridge: None,
        confetti: None,
        automation_control: None,
        runtime_paths: ExecServerRuntimePaths::from_optional_paths(
            Some(std::env::current_exe()?),
            None,
        )?,
    })
    .await
}

async fn spawn_child(session: &CodexSession, parent: ThreadId, depth: i32) -> Result<NewThread> {
    let mut options = StartThreadOptions::new(session.test_config.clone());
    options.session_source = Some(SessionSource::SubAgent(SubAgentSource::ThreadSpawn {
        parent_thread_id: parent,
        depth,
        agent_path: None,
        agent_nickname: None,
        agent_role: None,
    }));
    Ok(session.manager.start_thread(options).await?)
}

async fn start(thread: &CodexThread, text: &str) -> Result<()> {
    let result = thread
        .start_turn_if_idle(TurnInputRequest::user_input(vec![UserInput::Text {
            text: text.to_owned(),
            text_elements: Vec::new(),
        }]))
        .await?;
    ensure!(
        matches!(result, StartIfIdleSubmission::Started { .. }),
        "native turn did not start"
    );
    Ok(())
}

async fn status(thread: &CodexThread, expected: fn(&AgentStatus) -> bool) -> Result<()> {
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            if expected(&thread.agent_status().await) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .context("native child status timeout")
}

#[test]
fn interrupt_stops_native_child_and_grandchild_preserves_peer_and_cold_history_and_allows_resume()
-> Result<()> {
    run_native_test(async {
        let root = tempfile::tempdir()?;
        let server = server().await;
        let session = session(root.path(), &server, "Parent").await?;
        let child = spawn_child(&session, session.thread_id, 1).await?;
        let grandchild = spawn_child(&session, child.thread_id, 2).await?;
        let completed = spawn_child(&session, session.thread_id, 1).await?;
        let peer = session
            .manager
            .start_thread(StartThreadOptions::new(session.test_config.clone()))
            .await?;
        start(&completed.thread, "complete-child").await?;
        status(&completed.thread, |s| {
            matches!(s, AgentStatus::Completed(_))
        })
        .await?;
        session.manager.remove_thread(&completed.thread_id).await;
        for thread in [
            &session.thread,
            &child.thread,
            &grandchild.thread,
            &peer.thread,
        ] {
            start(thread, "hold-native-child").await?;
            status(thread, |s| matches!(s, AgentStatus::Running)).await?;
        }
        let tree = session
            .manager
            .list_agent_subtree_thread_ids(session.thread_id)
            .await?;
        ensure!(
            tree.contains(&child.thread_id) && tree.contains(&grandchild.thread_id),
            "actual spawn tree missing descendants"
        );
        ensure!(
            !tree.contains(&peer.thread_id),
            "unrelated root was included in subtree"
        );
        // Wait for real HTTP requests, rather than only a locally queued state.
        tokio::time::timeout(Duration::from_secs(10), async {
            while server
                .received_requests()
                .await
                .unwrap_or_default()
                .iter()
                .filter(|request| request.method.as_str() == "POST")
                .count()
                < 5
            {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await?;
        tokio::time::timeout(Duration::from_secs(1), session.interrupt_turn()).await??;
        {
            let mut jobs = session.descendant_interrupts.lock().await;
            while let Some(result) = jobs.join_next().await {
                result?;
            }
        }
        for thread in [&session.thread, &child.thread, &grandchild.thread] {
            status(thread, |s| matches!(s, AgentStatus::Interrupted)).await?;
        }
        assert_eq!(peer.thread.agent_status().await, AgentStatus::Running);
        assert!(
            session
                .manager
                .get_thread(completed.thread_id)
                .await
                .is_err(),
            "cold history was reloaded by Stop"
        );
        assert!(matches!(
            completed.thread.agent_status().await,
            AgentStatus::Completed(_)
        ));
        completed.thread.shutdown_and_wait().await?;
        start(&child.thread, "complete-child").await?;
        status(&child.thread, |s| matches!(s, AgentStatus::Completed(_))).await?;
        session.shutdown().await?;
        assert_eq!(peer.thread.agent_status().await, AgentStatus::Shutdown);
        Ok(())
    })
}

#[test]
fn shutdown_joins_native_children_releases_home_and_does_not_close_another_session() -> Result<()> {
    run_native_test(async {
        let root = tempfile::tempdir()?;
        let server = server().await;
        let first = session(root.path(), &server, "First").await?;
        let second = session(root.path(), &server, "Second").await?;
        let child = spawn_child(&first, first.thread_id, 1).await?;
        let manager = Arc::clone(&first.manager);
        start(&child.thread, "hold-native-child").await?;
        start(&second.thread, "hold-native-peer").await?;
        status(&child.thread, |s| matches!(s, AgentStatus::Running)).await?;
        status(&second.thread, |s| matches!(s, AgentStatus::Running)).await?;
        first.interrupt_turn().await?;
        first.shutdown().await?;
        assert_eq!(child.thread.agent_status().await, AgentStatus::Shutdown);
        assert!(manager.list_thread_ids().await.is_empty());
        assert_eq!(second.thread.agent_status().await, AgentStatus::Running);
        let reopened = session(root.path(), &server, "First").await?;
        reopened.shutdown().await?;
        second.shutdown().await?;
        Ok(())
    })
}
