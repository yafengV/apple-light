use codex_core_api::{
    AbsolutePathBuf, Arg0DispatchPaths, AskForApproval, AuthCredentialsStoreMode, AuthManager,
    CodexAppsToolsCache, CodexHomeUserInstructionsProvider, Config, Constrained,
    EnvironmentManager, ExecServerRuntimePaths, ExtensionRegistryBuilder, NewThread,
    PermissionProfile, Permissions, SessionSource, StartThreadOptions, ThreadManager,
    arg0_dispatch_or_else, build_models_manager, init_state_db,
    local_agent_graph_store_from_state_db, passthrough_image_store, resolve_installation_id,
    thread_store_from_config,
};
use codex_extension_api::ContextContributor;
use std::sync::Arc;

struct ShipiOSContext;
impl ContextContributor for ShipiOSContext {}

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

    // Thread startup has no model turn and must use only ShipiOS-owned state.
    config.model = None;
    config.cli_auth_credentials_store_mode = AuthCredentialsStoreMode::File;
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
    thread.shutdown_and_wait().await?;
    manager.remove_thread(&thread_id).await;
    assert_eq!(std::fs::read_dir(other_home)?.count(), 1);
    println!("isolated Codex thread started and stopped: {thread_id}");
    Ok(())
}
