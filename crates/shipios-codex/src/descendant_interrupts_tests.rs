use super::*;
use codex_protocol::protocol::{AgentStatus, SubAgentSource};
use std::time::Duration;
use wiremock::matchers::method;
use wiremock::{Mock, MockServer, ResponseTemplate};

pub(super) fn run_native_test(
    work: impl Future<Output = Result<()>> + Send + 'static,
) -> Result<()> {
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
        .and(|request: &wiremock::Request| {
            let body: serde_json::Value = serde_json::from_slice(&request.body).unwrap_or_default();
            body["input"]
                .as_array()
                .and_then(|items| items.iter().rev().find(|item| item["role"] == "user"))
                .and_then(|item| item["content"].as_array())
                .is_some_and(|parts| parts.iter().any(|part| part["text"] == "complete-child"))
        })
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

pub(super) async fn session(
    root: &std::path::Path,
    server: &MockServer,
    name: &str,
) -> Result<CodexSession> {
    CodexSession::start(options(root, server, name)?).await
}

fn options(root: &std::path::Path, server: &MockServer, name: &str) -> Result<SessionOptions> {
    let project = root.join("Project");
    std::fs::create_dir_all(&project)?;
    Ok(SessionOptions {
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
}

pub(super) async fn spawn_child(
    session: &CodexSession,
    parent: ThreadId,
    depth: i32,
) -> Result<NewThread> {
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

pub(super) async fn status(thread: &CodexThread, expected: fn(&AgentStatus) -> bool) -> Result<()> {
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

async fn drain_root_terminal(session: &CodexSession) -> Result<()> {
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            if matches!(
                session.next_event().await?,
                EventMsg::TurnComplete(_) | EventMsg::TurnAborted(_)
            ) {
                session.flush_rollout().await?;
                return Ok(());
            }
        }
    })
    .await?
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
        let snapshot = session.descendant_source().snapshot().await?;
        assert!(
            snapshot
                .iter()
                .any(|row| row.thread_id == child.thread_id.to_string()
                    && row.loaded
                    && row.status == "running"
                    && row.depth == Some(1))
        );
        assert!(
            snapshot
                .iter()
                .any(|row| row.thread_id == grandchild.thread_id.to_string()
                    && row.parent_thread_id == Some(child.thread_id.to_string())
                    && row.depth == Some(2))
        );
        assert!(
            snapshot
                .iter()
                .any(|row| row.thread_id == completed.thread_id.to_string()
                    && !row.loaded
                    && row.status == "notLoaded")
        );
        assert!(
            !snapshot
                .iter()
                .any(|row| row.thread_id == peer.thread_id.to_string())
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
fn descendant_history_reads_full_durable_and_cold_records_and_input_rejects_peer_and_busy_turns()
-> Result<()> {
    run_native_test(async {
        let root = tempfile::tempdir()?;
        let server = server().await;
        let parent = session(root.path(), &server, "History").await?;
        let child = spawn_child(&parent, parent.thread_id, 1).await?;
        let peer = parent
            .manager
            .start_thread(StartThreadOptions::new(parent.test_config.clone()))
            .await?;
        let source = parent.descendant_source();
        assert!(source.event_thread(&parent.thread_id()).await.is_err());
        assert!(
            source
                .event_thread(&peer.thread_id.to_string())
                .await
                .is_err()
        );
        assert!(std::sync::Arc::ptr_eq(
            &source.event_thread(&child.thread_id.to_string()).await?,
            &child.thread
        ));
        assert!(source.history(&parent.thread_id()).await.is_err());
        assert!(source.history(&peer.thread_id.to_string()).await.is_err());
        assert!(
            source
                .submit(&peer.thread_id.to_string(), "complete-child".into(), None)
                .await
                .is_err()
        );
        let (turn, steered) = source
            .submit(&child.thread_id.to_string(), "complete-child".into(), None)
            .await?;
        assert!(!steered);
        assert!(!turn.is_empty());
        status(&child.thread, |s| matches!(s, AgentStatus::Completed(_))).await?;
        tokio::time::timeout(Duration::from_secs(5), async {
            while !source
                .submission_finished(&child.thread_id.to_string(), &turn)
                .await?
            {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            Ok::<_, anyhow::Error>(())
        })
        .await??;
        assert!(
            !source
                .submission_finished(&child.thread_id.to_string(), "unknown")
                .await?
        );
        let history = source.history(&child.thread_id.to_string()).await?;
        assert!(
            history.iter().any(
                |event| event["type"] == "user_message" && event["message"] == "complete-child"
            )
        );
        assert!(history.iter().any(|event| event["type"] == "agent_message"
            && event["message"] == "Completed native child"));
        let long = "子会话完整回复🙂".repeat(20_000);
        let event = serde_json::from_value(json!({"type":"agent_message","message":long}))?;
        child
            .thread
            .append_rollout_items(&[codex_history::RolloutItem::EventMsg(event)])
            .await?;
        child.thread.flush_rollout().await?;
        let hidden = serde_json::from_value(json!({"type":"agent_reasoning_raw_content",
            "text":"private reasoning must remain hidden"}))?;
        let public =
            serde_json::from_value(json!({"type":"agent_reasoning","text":"public summary"}))?;
        child
            .thread
            .append_rollout_items(&[
                codex_history::RolloutItem::EventMsg(hidden),
                codex_history::RolloutItem::EventMsg(public),
            ])
            .await?;
        let full = source.history(&child.thread_id.to_string()).await?;
        let wire = serde_json::to_string(&full)?;
        assert!(wire.contains("public summary"));
        assert!(!wire.contains("private reasoning must remain hidden"));
        assert!(
            full.iter()
                .any(|event| event["message"].as_str() == Some(&long))
        );
        let (busy, _) = source
            .submit(
                &child.thread_id.to_string(),
                "hold-native-child".into(),
                None,
            )
            .await?;
        status(&child.thread, |s| matches!(s, AgentStatus::Running)).await?;
        assert!(
            !source
                .submission_finished(&child.thread_id.to_string(), &busy)
                .await?
        );
        assert!(
            source
                .submit(&child.thread_id.to_string(), "second".into(), None)
                .await
                .is_err()
        );
        assert!(
            source
                .submit(
                    &child.thread_id.to_string(),
                    "second".into(),
                    Some("wrong".into())
                )
                .await
                .is_err()
        );
        let (same, did_steer) = source
            .submit(
                &child.thread_id.to_string(),
                "child steering".into(),
                Some(busy.clone()),
            )
            .await?;
        assert_eq!(same, busy);
        assert!(did_steer);
        child.thread.submit(Op::Interrupt).await?;
        status(&child.thread, |s| matches!(s, AgentStatus::Interrupted)).await?;
        // AgentStatus is published before the terminal rollout event. Wait
        // for the same durable boundary that production monitoring requires.
        tokio::time::timeout(Duration::from_secs(5), async {
            while !source
                .submission_finished(&child.thread_id.to_string(), &busy)
                .await?
            {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            Ok::<_, anyhow::Error>(())
        })
        .await??;
        child.thread.flush_rollout().await?;
        parent.manager.remove_thread(&child.thread_id).await;
        let before = parent.manager.list_thread_ids().await;
        let cold = source.history(&child.thread_id.to_string()).await?;
        assert!(
            cold.iter()
                .any(|event| event["message"].as_str() == Some(&long))
        );
        assert_eq!(before, parent.manager.list_thread_ids().await);
        assert!(
            source
                .submit(&child.thread_id.to_string(), "cold cannot run".into(), None)
                .await
                .is_err()
        );
        child.thread.submit(Op::Shutdown).await?;
        status(&child.thread, |s| matches!(s, AgentStatus::Shutdown)).await?;
        parent.shutdown().await?;
        Ok(())
    })
}

#[test]
fn idle_parent_snapshot_tracks_child_completion_and_stop_cannot_interrupt_a_new_parent_turn()
-> Result<()> {
    run_native_test(async {
        let root = tempfile::tempdir()?;
        let server = server().await;
        let session = session(root.path(), &server, "IdleParent").await?;
        let source = session.descendant_source();
        let child = spawn_child(&session, session.thread_id, 1).await?;
        start(&session.thread, "complete-child").await?;
        status(&session.thread, |s| matches!(s, AgentStatus::Completed(_))).await?;
        drain_root_terminal(&session).await?;
        start(&child.thread, "hold-native-child").await?;
        status(&child.thread, |s| matches!(s, AgentStatus::Running)).await?;
        let rows = source.snapshot().await?;
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].status, "running");
        session.interrupt_idle_descendants().await;
        while let Some(result) = session.descendant_interrupts.lock().await.join_next().await {
            result?;
        }
        status(&child.thread, |s| matches!(s, AgentStatus::Interrupted)).await?;
        assert!(matches!(
            session.thread.agent_status().await,
            AgentStatus::Completed(_)
        ));
        start(&session.thread, "hold-native-root").await?;
        start(&child.thread, "hold-native-child").await?;
        status(&session.thread, |s| matches!(s, AgentStatus::Running)).await?;
        status(&child.thread, |s| matches!(s, AgentStatus::Running)).await?;
        session.interrupt_idle_descendants().await;
        while let Some(result) = session.descendant_interrupts.lock().await.join_next().await {
            result?;
        }
        assert_eq!(session.thread.agent_status().await, AgentStatus::Running);
        assert_eq!(child.thread.agent_status().await, AgentStatus::Running);
        session.interrupt_turn().await?;
        while let Some(result) = session.descendant_interrupts.lock().await.join_next().await {
            result?;
        }
        status(&child.thread, |s| matches!(s, AgentStatus::Interrupted)).await?;
        drain_root_terminal(&session).await?;
        start(&child.thread, "complete-child").await?;
        status(&child.thread, |s| matches!(s, AgentStatus::Completed(_))).await?;
        let rows = source.snapshot().await?;
        assert_eq!(rows[0].status, "completed");
        assert_eq!(rows[0].preview.as_deref(), Some("Completed native child"));
        session.shutdown().await?;
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

#[test]
fn cold_child_reloads_through_its_owner_without_a_parent_turn_and_keeps_native_identity()
-> Result<()> {
    run_native_test(async {
        for load_grandchild in [false, true] {
            let root = tempfile::tempdir()?;
            let server = server().await;
            let parent = session(root.path(), &server, "Reload").await?;
            let child = spawn_child(&parent, parent.thread_id, 1).await?;
            let grandchild = spawn_child(&parent, child.thread_id, 2).await?;
            for thread in [&parent.thread, &child.thread, &grandchild.thread] {
                start(thread, "complete-child").await?;
                status(thread, |s| matches!(s, AgentStatus::Completed(_))).await?;
            }
            let child_id = child.thread_id.to_string();
            let grandchild_id = grandchild.thread_id.to_string();
            let root_id = parent.thread_id();
            let rollout = parent.rollout_path().context("missing root rollout")?;
            parent.shutdown().await?;
            drop(child);
            drop(grandchild);
            let before = server.received_requests().await.unwrap_or_default().len();
            let resumed =
                CodexSession::resume(options(root.path(), &server, "Reload")?, rollout).await?;
            assert_eq!(resumed.thread_id(), root_id);
            let source = resumed.descendant_source();
            assert!(source.ensure_loaded(&root_id).await.is_err());
            assert!(
                source
                    .ensure_loaded(&uuid::Uuid::new_v4().to_string())
                    .await
                    .is_err()
            );
            assert!(
                !source
                    .snapshot()
                    .await?
                    .iter()
                    .find(|row| row.thread_id == child_id)
                    .context("missing cold child")?
                    .loaded
            );
            let target = if load_grandchild {
                &grandchild_id
            } else {
                &child_id
            };
            let mirror = source.clone();
            let (first, second) =
                tokio::join!(source.ensure_loaded(target), mirror.ensure_loaded(target));
            assert!(first?.loaded);
            assert!(second?.loaded);
            let rows = mirror.snapshot().await?;
            assert_eq!(rows.len(), 2);
            assert!(
                rows.iter()
                    .all(|row| row.loaded && row.status == "completed")
            );
            assert_eq!(
                server.received_requests().await.unwrap_or_default().len(),
                before,
                "Reload must not send a model message"
            );
            let native = source.event_thread(&child_id).await?;
            let config = native.config_snapshot().await;
            assert!(
                matches!(config.session_source, SessionSource::SubAgent(SubAgentSource::ThreadSpawn {parent_thread_id, ..}) if parent_thread_id.to_string() == root_id)
            );
            assert_eq!(config.model, "gpt-5.4");
            let (turn, steered) = source
                .submit(&child_id, "complete-child".into(), None)
                .await?;
            assert!(!steered);
            assert!(!turn.is_empty());
            status(&native, |s| matches!(s, AgentStatus::Completed(_))).await?;
            assert!(
                source
                    .history(&child_id)
                    .await?
                    .iter()
                    .any(|event| event["type"] == "task_started" && event["turn_id"] == turn)
            );
            resumed.shutdown().await?;
        }
        Ok(())
    })
}
