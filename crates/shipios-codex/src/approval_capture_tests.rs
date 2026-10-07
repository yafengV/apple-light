//! Real native waiters: no synthetic map or HTTP approval acknowledgement.
use super::descendant_interrupts_tests::{run_native_test, spawn_child, status};
use super::*;
use codex_protocol::protocol::{AgentStatus, ExecApprovalRequestEvent};
use std::time::Duration;
use wiremock::matchers::method;
use wiremock::{Mock, MockServer, ResponseTemplate};

async fn fixture(root: &std::path::Path) -> Result<(MockServer, CodexSession)> {
    fixture_with_mcp(root, None).await
}

async fn fixture_with_mcp(
    root: &std::path::Path,
    mcp_mode: Option<&str>,
) -> Result<(MockServer, CodexSession)> {
    let server = MockServer::start().await;
    let patch_path = root.join("Outside/patch-proof.txt");
    std::fs::create_dir_all(patch_path.parent().unwrap())?;
    Mock::given(method("POST"))
        .respond_with(move |request: &wiremock::Request| {
            let request: serde_json::Value = serde_json::from_slice(&request.body).unwrap();
            let items = request["input"].as_array().unwrap();
            let start = items.iter().rposition(|item| item["role"] == "user").unwrap_or(0);
            let prompt = items[start].to_string();
            let outputs = items[start..].iter().filter(|item| matches!(item["type"].as_str(), Some("function_call_output" | "custom_tool_call_output"))).count();
            let repeat = prompt.contains("native-repeat");
            let finished = outputs >= if repeat { 2 } else { 1 };
            let item = if finished {
                json!({"type":"message","id":"final","role":"assistant",
                    "content":[{"type":"output_text","text":"Approval fixture complete"}]})
            } else if prompt.contains("native-mcp") {
                if items[start..].iter().any(|item| item["type"] == "tool_search_output") {
                    json!({"type":"function_call","call_id":"reused-mcp-call","namespace":"mcp__shipios_capture",
                        "name":"first","arguments":"{}"})
                } else {
                    json!({"type":"tool_search_call","call_id":"native-mcp-search", "execution":"client",
                        "arguments":{"query":"shipios_capture first MCP tool", "limit":8}})
                }
            } else if prompt.contains("native-patch") {
                json!({"type":"custom_tool_call","call_id":"reused-patch","name":"apply_patch",
                    "input":format!("*** Begin Patch\n*** Add File: {}\n+patched\n*** End Patch", patch_path.display())})
            } else {
                // Deliberately reuse the same call ID in every actual native turn.
                let mut arguments = json!({"cmd":"printf approved > captured-proof.txt",
                    "sandbox_permissions":"require_escalated",
                    "justification":"Write a marker in the temporary approval fixture"});
                if prompt.contains("native-prefix") { arguments["prefix_rule"] = json!(["printf"]); }
                json!({"type":"function_call","call_id":"reused-approval","name":"exec_command",
                    "arguments":arguments.to_string()})
            };
            let events = [
                json!({"type":"response.created","response":{"id":"fixture","status":"in_progress","output":[]}}),
                json!({"type":"response.output_item.done","item":item}),
                json!({"type":"response.completed","response":{"id":"fixture","status":"completed",
                    "output":[item],"usage":{"input_tokens":10,"output_tokens":4,"total_tokens":14}}}),
            ];
            ResponseTemplate::new(200).insert_header("Content-Type", "text/event-stream")
                .set_body_string(events.iter().map(|e| format!("event: {}\ndata: {}\n\n", e["type"].as_str().unwrap(), e)).collect::<String>())
        })
        .mount(&server).await;
    let project = root.join("Project");
    std::fs::create_dir_all(&project)?;
    let executable = std::env::var_os("SHIPIOS_TEST_AGENT")
        .map(PathBuf::from)
        .unwrap_or(
            std::env::current_exe()?
                .parent()
                .context("test executable directory")?
                .parent()
                .context("target directory")?
                .join("shipios-agent"),
        );
    ensure!(
        executable.is_file(),
        "build shipios-agent before native approval tests, or set SHIPIOS_TEST_AGENT"
    );
    let session = CodexSession::start(SessionOptions {
        codex_home: root.join("Agent"),
        project_root: project,
        additional_folders: vec![],
        base_url: format!("{}/v1", server.uri()),
        model: "gpt-5.4".into(),
        api_key: Some("approval-fixture-key".into()),
        read_only: false,
        permissions: SessionPermissions {
            sandbox_mode: SessionSandboxMode::ReadOnly,
            ..SessionPermissions::default()
        },
        permission_profile_id: None,
        responses: SessionResponsePreferences::default(),
        web_search: SessionWebSearch::default(),
        mcp_servers: mcp_mode
            .map(|mode| {
                vec![ShipMcpServer {
                    name: "shipios_capture".into(),
                    enabled: true,
                    transport: ShipMcpTransport::Stdio,
                    command: "/usr/bin/python3".into(),
                    arguments: vec![
                        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                            .join(if mode == "capture_url" {
                                "../../apps/macos/Tests/Fixtures/subagent_mcp_server.py"
                            } else {
                                "../../apps/macos/Tests/Fixtures/mcp_server.py"
                            })
                            .to_string_lossy()
                            .into_owned(),
                        if mode == "native_gate" {
                            "stdio".into()
                        } else {
                            mode.into()
                        },
                    ],
                    environment: vec![
                        ShipMcpKeyValue {
                            key: "SHIPIOS_CODEX_PROBE".into(),
                            value: if mode == "native_gate" {
                                String::new()
                            } else {
                                "1".into()
                            },
                        },
                        ShipMcpKeyValue {
                            key: "CALL_LOG".into(),
                            value: root
                                .join("mcp-replies.jsonl")
                                .to_string_lossy()
                                .into_owned(),
                        },
                    ],
                    environment_passthrough: vec![],
                    working_directory: String::new(),
                    url: String::new(),
                    bearer_token_environment_variable: String::new(),
                    headers: vec![],
                    environment_headers: vec![],
                }]
            })
            .unwrap_or_default(),
        hooks: vec![],
        browser_bridge: None,
        confetti: None,
        automation_control: None,
        runtime_paths: ExecServerRuntimePaths::from_optional_paths(Some(executable), None)?,
    })
    .await?;
    Ok((server, session))
}

async fn request(thread: &CodexThread) -> Result<ExecApprovalRequestEvent> {
    exec_request(thread, "native-approval").await
}

async fn exec_request(thread: &CodexThread, prompt: &str) -> Result<ExecApprovalRequestEvent> {
    let accepted = thread
        .start_turn_if_idle(TurnInputRequest::user_input(vec![UserInput::Text {
            text: prompt.into(),
            text_elements: vec![],
        }]))
        .await?;
    let StartIfIdleSubmission::Started { turn_id } = accepted else {
        bail!("child is not idle")
    };
    tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            let event = thread.next_event().await?;
            if let EventMsg::ExecApprovalRequest(request) = event.msg {
                ensure!(request.turn_id == turn_id, "approval has wrong native turn");
                return Ok(request);
            }
        }
    })
    .await
    .context("native approval timeout")?
}

async fn ticket(
    source: &DescendantSource,
    child: ThreadId,
    request: &ExecApprovalRequestEvent,
) -> Result<codex_core::CapturedApproval> {
    source
        .claim_approval(
            &child.to_string(),
            &request.turn_id,
            request.approval_id.as_deref().unwrap_or(&request.call_id),
            request.started_at_ms,
        )
        .await
}

async fn mcp_request(
    thread: &CodexThread,
    prompt: Option<&str>,
    previous_turn: Option<&str>,
) -> Result<(codex_protocol::approvals::ElicitationRequestEvent, String)> {
    let observed_turn = if let Some(prompt) = prompt {
        match thread
            .start_turn_if_idle(TurnInputRequest::user_input(vec![UserInput::Text {
                text: prompt.into(),
                text_elements: vec![],
            }]))
            .await?
        {
            StartIfIdleSubmission::Started { turn_id } => turn_id,
            _ => bail!("MCP child is not idle"),
        }
    } else {
        previous_turn
            .context("missing observed MCP turn")?
            .to_owned()
    };
    tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            let event = thread.next_event().await?;
            if let EventMsg::ElicitationRequest(request) = event.msg {
                return Ok((request, observed_turn));
            }
            if let EventMsg::TurnComplete(_) | EventMsg::Error(_) = event.msg {
                bail!("MCP request did not arrive: {:?}", event.msg);
            }
        }
    })
    .await
    .context("native MCP request timeout")?
}

#[test]
fn native_child_mcp_capture_rejects_reused_generation_root_peer_and_ordinary_reply() -> Result<()> {
    run_native_test(async {
        let root = tempfile::tempdir()?;
        let (_server, parent) = fixture_with_mcp(root.path(), Some("stdio_form")).await?;
        let child = spawn_child(&parent, parent.thread_id, 1).await?;
        let peer = parent
            .manager
            .start_thread(StartThreadOptions::new(parent.test_config.clone()))
            .await?;
        let source = parent.descendant_source();
        let (first, first_turn) =
            mcp_request(&child.thread, Some("native-mcp native-repeat"), None).await?;
        assert!(
            first.turn_id.is_none(),
            "Actual server forms use the runtime router"
        );
        for id in [parent.thread_id, peer.thread_id] {
            assert!(
                source
                    .claim_elicitation(&id.to_string(), &first_turn, &first)
                    .await
                    .is_err()
            );
        }
        for identity in ["turn", "server", "request-id"] {
            let mut wrong = first.clone();
            match identity {
                "turn" => wrong.turn_id = Some("wrong-turn".into()),
                "server" => wrong.server_name = "wrong-server".into(),
                _ => wrong.id = serde_json::from_value(json!("wrong-request"))?,
            }
            assert!(
                source
                    .claim_elicitation(&child.thread_id.to_string(), &first_turn, &wrong)
                    .await
                    .is_err()
            );
        }
        let reply = source
            .claim_elicitation(&child.thread_id.to_string(), &first_turn, &first)
            .await?;
        assert!(
            source
                .claim_elicitation(&child.thread_id.to_string(), &first_turn, &first)
                .await
                .is_err()
        );
        // An ID-only legacy reply cannot fulfill a waiter claimed by the host.
        child
            .thread
            .submit(Op::ResolveElicitation {
                server_name: first.server_name.clone(),
                request_id: serde_json::from_value(serde_json::to_value(&first.id)?)?,
                decision: codex_protocol::approvals::ElicitationAction::Decline,
                content: None,
                meta: None,
            })
            .await?;
        // This acknowledged no-op follows the legacy reply in the same native
        // queue, so the test does not race response delivery against submission.
        let (barrier, processed) = tokio::sync::oneshot::channel();
        child
            .thread
            .submit(Op::TurnSettings {
                turn_id: first_turn.clone(),
                update: Default::default(),
                reply: barrier,
            })
            .await?;
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(5), processed).await??,
            codex_protocol::protocol::TurnSettingsUpdateOutcome::Rejected {
                reason: "turn settings updates require the step_model_switching feature".into(),
            }
        );
        assert!(!reply.is_closed());
        assert!(
            reply
                .resolve(
                    codex_protocol::approvals::ElicitationAction::Accept,
                    Some(json!({"reason":"Approved original child", "count":2})),
                    None
                )
                .await
        );
        let (second, second_turn) = mcp_request(&child.thread, None, Some(&first_turn)).await?;
        assert_eq!(first_turn, second_turn);
        assert_ne!(
            first.id, second.id,
            "Core router IDs remain distinct when the server reuses its raw ID"
        );
        assert!(
            source
                .claim_elicitation(&child.thread_id.to_string(), &first_turn, &first)
                .await
                .is_err()
        );
        let reply = source
            .claim_elicitation(&child.thread_id.to_string(), &second_turn, &second)
            .await?;
        assert!(
            reply
                .resolve(
                    codex_protocol::approvals::ElicitationAction::Accept,
                    Some(json!({"reason":"Approved original child", "count":2})),
                    None
                )
                .await
        );
        status(&child.thread, |s| matches!(s, AgentStatus::Completed(_))).await?;
        let log = std::fs::read_to_string(root.path().join("mcp-replies.jsonl"))?;
        let responses: Vec<serde_json::Value> = log
            .lines()
            .map(serde_json::from_str)
            .collect::<std::result::Result<_, _>>()?;
        assert_eq!(responses.len(), 2);
        assert!(responses.iter().all(|response| response["action"] == "accept" && response["content"]["count"] == 2));
        peer.thread.submit(Op::Shutdown).await?;
        parent.shutdown().await?;
        Ok(())
    })
}

#[test]
fn native_child_url_capture_closes_on_stop_and_cannot_reply_to_replacement_turn() -> Result<()> {
    run_native_test(async {
        let root = tempfile::tempdir()?;
        let (_server, parent) = fixture_with_mcp(root.path(), Some("capture_url")).await?;
        let child = spawn_child(&parent, parent.thread_id, 1).await?;
        let source = parent.descendant_source();
        let (first, first_turn) = mcp_request(&child.thread, Some("native-mcp"), None).await?;
        let reply = source
            .claim_elicitation(&child.thread_id.to_string(), &first_turn, &first)
            .await?;
        assert!(
            source
                .interrupt(&child.thread_id.to_string(), &first_turn)
                .await?
        );
        status(&child.thread, |s| matches!(s, AgentStatus::Interrupted)).await?;
        assert!(reply.is_closed());
        let (second, second_turn) = mcp_request(&child.thread, Some("native-mcp"), None).await?;
        assert_ne!(first_turn, second_turn);
        assert!(
            !reply
                .resolve(
                    codex_protocol::approvals::ElicitationAction::Accept,
                    Some(json!({"reason":"Approved original child", "count":2})),
                    None
                )
                .await
        );
        assert!(
            source
                .claim_elicitation(&child.thread_id.to_string(), &first_turn, &first)
                .await
                .is_err()
        );
        let next = source
            .claim_elicitation(&child.thread_id.to_string(), &second_turn, &second)
            .await?;
        assert!(
            next.resolve(
                codex_protocol::approvals::ElicitationAction::Cancel,
                None,
                None
            )
            .await
        );
        status(&child.thread, |s| matches!(s, AgentStatus::Completed(_))).await?;
        let log = std::fs::read_to_string(root.path().join("mcp-replies.jsonl"))?;
        let responses: Vec<serde_json::Value> = log
            .lines()
            .map(serde_json::from_str)
            .collect::<std::result::Result<_, _>>()?;
        assert_eq!(responses.len(), 1);
        assert_eq!(responses[0]["action"], "cancel");
        parent.shutdown().await?;
        Ok(())
    })
}

#[test]
fn native_child_mcp_tool_gate_capture_checks_native_generation_then_executes() -> Result<()> {
    run_native_test(async {
        let root = tempfile::tempdir()?;
        let (_server, parent) = fixture_with_mcp(root.path(), Some("native_gate")).await?;
        let child = spawn_child(&parent, parent.thread_id, 1).await?;
        let source = parent.descendant_source();
        let (request, turn) = mcp_request(&child.thread, Some("native-mcp"), None).await?;
        assert_eq!(request.turn_id.as_deref(), Some(turn.as_str()));
        let native = serde_json::to_value(&request.request)?;
        assert!(
            native["_meta"][codex_core::NATIVE_ELICITATION_GENERATION_KEY]
                .as_u64()
                .unwrap()
                > 0
        );
        let mut wrong = request.clone();
        let mut changed = native;
        changed["_meta"][codex_core::NATIVE_ELICITATION_GENERATION_KEY] = json!(999999);
        wrong.request = serde_json::from_value(changed)?;
        assert!(
            source
                .claim_elicitation(&child.thread_id.to_string(), &turn, &wrong)
                .await
                .is_err()
        );
        let reply = source
            .claim_elicitation(&child.thread_id.to_string(), &turn, &request)
            .await?;
        assert!(
            reply
                .resolve(
                    codex_protocol::approvals::ElicitationAction::Accept,
                    Some(json!({})),
                    None
                )
                .await
        );
        status(&child.thread, |s| matches!(s, AgentStatus::Completed(_))).await?;
        let log = std::fs::read_to_string(root.path().join("mcp-replies.jsonl"))?;
        let call: serde_json::Value = serde_json::from_str(log.trim())?;
        assert_eq!(call["name"], "first");
        parent.shutdown().await?;
        Ok(())
    })
}

#[test]
fn exact_child_stop_preserves_parent_sibling_peer_and_rejects_a_later_turn() -> Result<()> {
    run_native_test(async {
        let root = tempfile::tempdir()?;
        let (_server, parent) = fixture(root.path()).await?;
        let child = spawn_child(&parent, parent.thread_id, 1).await?;
        let sibling = spawn_child(&parent, parent.thread_id, 1).await?;
        let peer = parent
            .manager
            .start_thread(StartThreadOptions::new(parent.test_config.clone()))
            .await?;
        let parent_req = request(&parent.thread).await?;
        let req = request(&child.thread).await?;
        let sibling_req = request(&sibling.thread).await?;
        let source = parent.descendant_source();
        let reply = ticket(&source, child.thread_id, &req).await?;
        for id in [parent.thread_id, peer.thread_id] {
            assert!(
                source
                    .interrupt(&id.to_string(), &req.turn_id)
                    .await
                    .is_err()
            );
        }
        assert!(
            !source
                .interrupt(&child.thread_id.to_string(), "old-turn")
                .await?
        );
        assert!(!reply.is_closed());
        assert!(
            source
                .interrupt(&child.thread_id.to_string(), &req.turn_id)
                .await?
        );
        status(&child.thread, |s| matches!(s, AgentStatus::Interrupted)).await?;
        assert!(reply.is_closed());
        assert!(matches!(
            parent.thread.agent_status().await,
            AgentStatus::Running
        ));
        assert!(matches!(
            sibling.thread.agent_status().await,
            AgentStatus::Running
        ));
        assert!(!root.path().join("Project/captured-proof.txt").exists());
        let next = request(&child.thread).await?;
        assert_ne!(req.turn_id, next.turn_id);
        assert!(
            !source
                .interrupt(&child.thread_id.to_string(), &req.turn_id)
                .await?
        );
        let next_reply = ticket(&source, child.thread_id, &next).await?;
        assert!(!next_reply.is_closed());
        assert!(next_reply.resolve(ReviewDecision::Approved).await?);
        status(&child.thread, |s| matches!(s, AgentStatus::Completed(_))).await?;
        assert_eq!(
            std::fs::read_to_string(root.path().join("Project/captured-proof.txt"))?,
            "approved"
        );
        assert!(
            source
                .interrupt(&sibling.thread_id.to_string(), &sibling_req.turn_id)
                .await?
        );
        assert!(
            parent
                .thread
                .interrupt_turn_if_active(&parent_req.turn_id)
                .await
        );
        peer.thread.submit(Op::Shutdown).await?;
        child.thread.submit(Op::Shutdown).await?;
        status(&child.thread, |s| matches!(s, AgentStatus::Shutdown)).await?;
        parent.manager.remove_thread(&child.thread_id).await;
        assert!(
            source
                .interrupt(&child.thread_id.to_string(), &next.turn_id)
                .await
                .is_err()
        );
        parent.shutdown().await?;
        Ok(())
    })
}

#[test]
fn child_approval_claim_is_exact_once_rejects_root_peer_and_wrong_identity_then_executes()
-> Result<()> {
    run_native_test(async {
        let root = tempfile::tempdir()?;
        let (_server, parent) = fixture(root.path()).await?;
        let child = spawn_child(&parent, parent.thread_id, 1).await?;
        let peer = parent
            .manager
            .start_thread(StartThreadOptions::new(parent.test_config.clone()))
            .await?;
        let req = request(&child.thread).await?;
        let source = parent.descendant_source();
        for id in [parent.thread_id, peer.thread_id] {
            assert!(ticket(&source, id, &req).await.is_err());
        }
        let mut wrong = req.clone();
        wrong.turn_id = "old-turn".into();
        assert!(ticket(&source, child.thread_id, &wrong).await.is_err());
        wrong = req.clone();
        wrong.started_at_ms -= 1;
        assert!(ticket(&source, child.thread_id, &wrong).await.is_err());
        wrong = req.clone();
        wrong.approval_id = Some("wrong-call".into());
        assert!(ticket(&source, child.thread_id, &wrong).await.is_err());
        let reply = ticket(&source, child.thread_id, &req).await?;
        assert!(!reply.is_closed());
        assert!(ticket(&source, child.thread_id, &req).await.is_err());
        // Legacy ID-only delivery cannot bypass the captured reply owner.
        child
            .thread
            .submit(Op::ExecApproval {
                id: req.approval_id.clone().unwrap_or(req.call_id.clone()),
                turn_id: Some(req.turn_id.clone()),
                decision: ReviewDecision::Approved,
            })
            .await?;
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert!(!root.path().join("Project/captured-proof.txt").exists());
        assert!(!reply.is_closed());
        assert!(reply.resolve(ReviewDecision::Approved).await?);
        status(&child.thread, |s| matches!(s, AgentStatus::Completed(_))).await?;
        assert_eq!(
            std::fs::read_to_string(root.path().join("Project/captured-proof.txt"))?,
            "approved"
        );
        parent.shutdown().await?;
        Ok(())
    })
}

#[test]
fn cancelled_child_ticket_cannot_approve_reused_call_in_a_later_turn() -> Result<()> {
    run_native_test(async {
        let root = tempfile::tempdir()?;
        let (_server, parent) = fixture(root.path()).await?;
        let child = spawn_child(&parent, parent.thread_id, 1).await?;
        let source = parent.descendant_source();
        let first = exec_request(&child.thread, "native-prefix").await?;
        let old = ticket(&source, child.thread_id, &first).await?;
        child.thread.submit(Op::Interrupt).await?;
        status(&child.thread, |s| matches!(s, AgentStatus::Interrupted)).await?;
        // Status precedes the persisted terminal and complete waiter teardown.
        tokio::time::timeout(Duration::from_secs(5), async {
            while !old.is_closed() {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await?;
        let second = request(&child.thread).await?;
        assert_eq!(first.call_id, second.call_id);
        assert_ne!(first.turn_id, second.turn_id);
        assert!(second.started_at_ms > first.started_at_ms);
        assert!(ticket(&source, child.thread_id, &first).await.is_err());
        let new = ticket(&source, child.thread_id, &second).await?;
        let amendment = first
            .proposed_execpolicy_amendment
            .clone()
            .context("native prefix proposal")?;
        assert!(
            !old.resolve(ReviewDecision::ApprovedExecpolicyAmendment {
                proposed_execpolicy_amendment: amendment,
            })
            .await?
        );
        assert!(!root.path().join("Agent/rules/default.rules").exists());
        assert!(!root.path().join("Project/captured-proof.txt").exists());
        assert!(!new.is_closed());
        assert!(
            new.resolve(ReviewDecision::denied("Approval fixture denied"))
                .await?
        );
        status(&child.thread, |s| matches!(s, AgentStatus::Completed(_))).await?;
        assert!(!root.path().join("Project/captured-proof.txt").exists());
        parent.shutdown().await?;
        Ok(())
    })
}

#[test]
fn child_approval_abort_stops_only_its_turn_and_drop_closes_original_waiter() -> Result<()> {
    run_native_test(async {
        let root = tempfile::tempdir()?;
        let (_server, parent) = fixture(root.path()).await?;
        let first = spawn_child(&parent, parent.thread_id, 1).await?;
        let second = spawn_child(&parent, parent.thread_id, 1).await?;
        let source = parent.descendant_source();
        let a = request(&first.thread).await?;
        let b = request(&second.thread).await?;
        let reply_a = ticket(&source, first.thread_id, &a).await?;
        let reply_b = ticket(&source, second.thread_id, &b).await?;
        assert!(reply_a.resolve(ReviewDecision::Abort).await?);
        status(&first.thread, |s| matches!(s, AgentStatus::Interrupted)).await?;
        assert!(!reply_b.is_closed());
        assert_eq!(second.thread.agent_status().await, AgentStatus::Running);
        drop(reply_b);
        status(&second.thread, |s| matches!(s, AgentStatus::Completed(_))).await?;
        assert!(ticket(&source, second.thread_id, &b).await.is_err());
        assert!(!root.path().join("Project/captured-proof.txt").exists());
        parent.shutdown().await?;
        Ok(())
    })
}

#[test]
fn same_turn_call_reuse_requires_the_new_request_instance() -> Result<()> {
    run_native_test(async {
        let root = tempfile::tempdir()?;
        let (_server, parent) = fixture(root.path()).await?;
        let child = spawn_child(&parent, parent.thread_id, 1).await?;
        let source = parent.descendant_source();
        let first = exec_request(&child.thread, "native-repeat").await?;
        assert!(
            ticket(&source, child.thread_id, &first)
                .await?
                .resolve(ReviewDecision::denied("Try again"))
                .await?
        );
        let second = tokio::time::timeout(Duration::from_secs(15), async {
            loop {
                if let EventMsg::ExecApprovalRequest(request) = child.thread.next_event().await?.msg
                {
                    return Ok::<_, anyhow::Error>(request);
                }
            }
        })
        .await??;
        assert_eq!(first.turn_id, second.turn_id);
        assert_eq!(first.call_id, second.call_id);
        assert!(second.started_at_ms > first.started_at_ms);
        assert!(ticket(&source, child.thread_id, &first).await.is_err());
        let new = ticket(&source, child.thread_id, &second).await?;
        assert!(!root.path().join("Project/captured-proof.txt").exists());
        assert!(new.resolve(ReviewDecision::Approved).await?);
        status(&child.thread, |s| matches!(s, AgentStatus::Completed(_))).await?;
        assert_eq!(
            std::fs::read_to_string(root.path().join("Project/captured-proof.txt"))?,
            "approved"
        );
        parent.shutdown().await?;
        Ok(())
    })
}

#[test]
fn patch_approval_uses_its_original_waiter_and_writes_only_after_approval() -> Result<()> {
    run_native_test(async {
        let root = tempfile::tempdir()?;
        let (_server, parent) = fixture(root.path()).await?;
        let child = spawn_child(&parent, parent.thread_id, 1).await?;
        let source = parent.descendant_source();
        child
            .thread
            .start_turn_if_idle(TurnInputRequest::user_input(vec![UserInput::Text {
                text: "native-patch".into(),
                text_elements: vec![],
            }]))
            .await?;
        let request = tokio::time::timeout(Duration::from_secs(15), async {
            loop {
                if let EventMsg::ApplyPatchApprovalRequest(request) =
                    child.thread.next_event().await?.msg
                {
                    return Ok::<_, anyhow::Error>(request);
                }
            }
        })
        .await??;
        let reply = source
            .claim_approval(
                &child.thread_id.to_string(),
                &request.turn_id,
                &request.call_id,
                request.started_at_ms,
            )
            .await?;
        assert!(
            source
                .claim_approval(
                    &child.thread_id.to_string(),
                    &request.turn_id,
                    &request.call_id,
                    request.started_at_ms
                )
                .await
                .is_err()
        );
        assert!(!root.path().join("Outside/patch-proof.txt").exists());
        assert!(reply.resolve(ReviewDecision::Approved).await?);
        if let Err(error) = status(&child.thread, |s| matches!(s, AgentStatus::Completed(_))).await
        {
            let state = child.thread.agent_status().await;
            let events = source.history(&child.thread_id.to_string()).await?;
            return Err(error.context(format!(
                "observed status {state:?}; last public events {:?}",
                events.iter().rev().take(8).collect::<Vec<_>>()
            )));
        }
        assert_eq!(
            std::fs::read_to_string(root.path().join("Outside/patch-proof.txt"))?,
            "patched\n"
        );
        parent.shutdown().await?;
        Ok(())
    })
}

#[test]
fn captured_prefix_approval_persists_the_native_proposal_before_execution() -> Result<()> {
    run_native_test(async {
        let root = tempfile::tempdir()?;
        let (_server, parent) = fixture(root.path()).await?;
        let child = spawn_child(&parent, parent.thread_id, 1).await?;
        let source = parent.descendant_source();
        let req = exec_request(&child.thread, "native-prefix").await?;
        let amendment = req
            .proposed_execpolicy_amendment
            .clone()
            .context("native prefix proposal")?;
        assert!(!root.path().join("Agent/rules/default.rules").exists());
        assert!(
            ticket(&source, child.thread_id, &req)
                .await?
                .resolve(ReviewDecision::ApprovedExecpolicyAmendment {
                    proposed_execpolicy_amendment: amendment
                })
                .await?
        );
        status(&child.thread, |s| matches!(s, AgentStatus::Completed(_))).await?;
        let policy = std::fs::read_to_string(root.path().join("Agent/rules/default.rules"))?;
        assert!(policy.contains("printf") && policy.contains("allow"));
        assert_eq!(
            std::fs::read_to_string(root.path().join("Project/captured-proof.txt"))?,
            "approved"
        );
        parent.shutdown().await?;
        Ok(())
    })
}
