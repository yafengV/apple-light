use codex_core_api::{
    AbsolutePathBuf, Arg0DispatchPaths, AskForApproval, AuthCredentialsStoreMode, AuthManager,
    CodexAppsToolsCache, CodexHomeUserInstructionsProvider, Config, Constrained,
    EnvironmentManager, EventMsg, ExecServerRuntimePaths, ExtensionRegistryBuilder, NewThread,
    PermissionProfile, Permissions, SessionSource, StartIfIdleSubmission, StartThreadOptions,
    ThreadManager, TurnInputRequest, UserInput, arg0_dispatch_or_else, build_models_manager,
    init_state_db, local_agent_graph_store_from_state_db, passthrough_image_store,
    resolve_installation_id, thread_store_from_config,
};
use codex_extension_api::ContextContributor;
use serde_json::json;
use std::sync::Arc;
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

struct ShipiOSContext;
impl ContextContributor for ShipiOSContext {}

fn sse(events: Vec<serde_json::Value>) -> String {
    events
        .into_iter()
        .map(|event| {
            format!(
                "event: {}\ndata: {event}\n\n",
                event["type"].as_str().unwrap()
            )
        })
        .collect()
}

fn main() -> anyhow::Result<()> {
    arg0_dispatch_or_else(run_main)
}

async fn run_main(arg0_paths: Arg0DispatchPaths) -> anyhow::Result<()> {
    let root = tempfile::tempdir()?;
    let shipios_home = root.path().join("ShipiOS/Agent");
    let other_home = root.path().join("other-codex");
    std::fs::create_dir_all(&shipios_home)?;
    std::fs::create_dir_all(&other_home)?;

    // If the isolated loader reads either home config, this invalid TOML fails.
    std::fs::write(shipios_home.join("config.toml"), "invalid = [")?;
    std::fs::write(other_home.join("config.toml"), "invalid = [")?;

    let mut config = Config::load_default_with_cli_overrides_for_codex_home(
        shipios_home.clone(),
        vec![(
            "model".to_owned(),
            toml::Value::String("shipios-poc-model".to_owned()),
        )],
    )
    .await?;
    let other =
        Config::load_default_with_cli_overrides_for_codex_home(other_home.clone(), vec![]).await?;
    assert_eq!(config.codex_home.to_path_buf(), shipios_home);
    assert_eq!(other.codex_home.to_path_buf(), other_home);
    assert_eq!(config.model.as_deref(), Some("shipios-poc-model"));
    assert_ne!(config.model, other.model);

    let mut extensions = ExtensionRegistryBuilder::<Config>::new();
    extensions.prompt_contributor(Arc::new(ShipiOSContext));
    let extensions = Arc::new(extensions.build());
    assert_eq!(extensions.context_contributors().len(), 1);

    // A loopback server supplies one deterministic model response.
    let server = MockServer::start().await;
    let response = sse(vec![
        json!({"type": "response.created", "response": {"id": "resp-1"}}),
        json!({"type": "response.output_item.done", "item": {
            "type": "message", "role": "assistant", "id": "msg-1",
            "content": [{"type": "output_text", "text": "ShipiOS mock reply"}]
        }}),
        json!({"type": "response.completed", "response": {
            "id": "resp-1", "usage": {
                "input_tokens": 0, "input_tokens_details": null,
                "output_tokens": 0, "output_tokens_details": null, "total_tokens": 0
            }
        }}),
    ]);
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

    config.model = None;
    config.cli_auth_credentials_store_mode = AuthCredentialsStoreMode::File;
    let mut provider = config.model_provider.clone();
    provider.name = "ShipiOS Mock".to_owned();
    provider.base_url = Some(format!("{}/v1", server.uri()));
    provider.env_key = None;
    provider.experimental_bearer_token = None;
    provider.auth = None;
    provider.aws = None;
    provider.requires_openai_auth = false;
    provider.supports_websockets = false;
    provider.supports_standalone_web_search = false;
    config.model_provider_id = "shipios-mock".to_owned();
    config
        .model_providers
        .insert("shipios-mock".to_owned(), provider.clone());
    config.model_provider = provider;
    let project = root.path().join("project");
    std::fs::create_dir_all(&project)?;
    let project = AbsolutePathBuf::from_absolute_path_checked(project)?;
    config.cwd = project.clone();
    config.workspace_roots = vec![project];
    config.workspace_roots_explicit = true;
    config.permissions = Permissions::from_approval_and_profile(
        Constrained::allow_any(AskForApproval::Never),
        Constrained::allow_any(PermissionProfile::read_only()),
    )?;
    let state_db = init_state_db(&config).await;
    let auth_manager = AuthManager::shared_from_config(&config, false).await?;
    let thread_store = thread_store_from_config(&config, state_db.clone());
    let runtime_paths = ExecServerRuntimePaths::from_optional_paths(
        arg0_paths.codex_self_exe,
        arg0_paths.codex_linux_sandbox_exe,
    )?;
    let environment_manager = Arc::new(
        EnvironmentManager::from_codex_home(
            config.codex_home.clone(),
            Some(runtime_paths),
            config.http_client_factory(),
        )
        .await?,
    );
    let installation_id = resolve_installation_id(&config.codex_home).await?;
    let manager = ThreadManager::new(
        &config,
        Arc::clone(&auth_manager),
        build_models_manager(&config, auth_manager),
        CodexAppsToolsCache::default(),
        SessionSource::Exec,
        environment_manager,
        extensions,
        Arc::new(CodexHomeUserInstructionsProvider::new(
            config.codex_home.clone(),
        )),
        None,
        passthrough_image_store(),
        thread_store,
        local_agent_graph_store_from_state_db(state_db.as_ref()),
        installation_id,
        None,
        None,
    );
    let NewThread {
        thread_id,
        thread,
        session_configured,
    } = manager
        .start_thread(StartThreadOptions::new(config))
        .await?;
    assert_eq!(session_configured.thread_id, thread_id);
    let rollout = thread
        .rollout_path()
        .expect("local thread has a rollout path");
    assert!(rollout.starts_with(&shipios_home));

    let submission = thread
        .start_turn_if_idle(TurnInputRequest::user_input(vec![UserInput::Text {
            text: "Reply with the fixture text".to_owned(),
            text_elements: Vec::new(),
        }]))
        .await?;
    assert!(matches!(submission, StartIfIdleSubmission::Started { .. }));
    let mut saw_message = false;
    let reply = loop {
        let event =
            tokio::time::timeout(std::time::Duration::from_secs(10), thread.next_event()).await??;
        match event.msg {
            EventMsg::AgentMessage(message) => {
                saw_message |= message.message == "ShipiOS mock reply";
            }
            EventMsg::TurnComplete(turn) => break turn.last_agent_message,
            EventMsg::Error(error) => anyhow::bail!("Codex turn failed: {}", error.message),
            EventMsg::TurnAborted(_) => anyhow::bail!("Codex turn was aborted"),
            _ => {}
        }
    };
    assert!(
        saw_message,
        "the reply must arrive before the completion event"
    );
    assert_eq!(reply.as_deref(), Some("ShipiOS mock reply"));
    thread.shutdown_and_wait().await?;
    manager.remove_thread(&thread_id).await;
    assert!(rollout.is_file());
    assert_eq!(std::fs::read_dir(other_home)?.count(), 1);
    let requests = server
        .received_requests()
        .await
        .expect("mock request history");
    assert_eq!(requests.len(), 1);
    let turns: Vec<_> = requests
        .iter()
        .filter(|request| {
            request.method.as_str() == "POST" && request.url.path() == "/v1/responses"
        })
        .collect();
    assert_eq!(turns.len(), 1);
    assert!(turns[0].headers.get("authorization").is_none());
    let body: serde_json::Value = serde_json::from_slice(&turns[0].body)?;
    assert!(body.to_string().contains("Reply with the fixture text"));
    server.verify().await;
    println!("isolated Codex turn streamed and persisted: {thread_id}");
    Ok(())
}
