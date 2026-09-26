//! Host adapter for the pinned Codex Core runtime. The desktop still uses its
//! existing chat transport until the Agent RPC and event mapping are connected.

use anyhow::{Context, Result, anyhow, bail, ensure};
use codex_core_api::{
    AbsolutePathBuf, AskForApproval, AuthCredentialsStoreMode, AuthKeyringBackendKind, AuthManager,
    CodexAppsToolsCache, CodexHomeUserInstructionsProvider, CodexThread, Config, Constrained,
    EnvironmentManager, EventMsg, ExecServerRuntimePaths, ExtensionRegistryBuilder, NewThread,
    PermissionProfile, Permissions, SessionSource, StartIfIdleSubmission, StartThreadOptions,
    ThreadId, ThreadManager, TurnInputRequest, UserInput, build_models_manager, init_state_db,
    local_agent_graph_store_from_state_db, passthrough_image_store, resolve_installation_id,
    thread_store_from_config,
};
use codex_login::{login_with_api_key, logout};
use std::{
    collections::HashSet,
    path::PathBuf,
    sync::{Arc, Mutex, OnceLock},
};
use url::Url;

/// Caller-owned values; `api_key` comes from the ShipiOS Keychain over private IPC.
/// Give each live session its own Codex home to isolate ephemeral auth.
pub struct SessionOptions {
    pub codex_home: PathBuf,
    pub project_root: PathBuf,
    pub base_url: String,
    pub model: String,
    pub api_key: Option<String>,
    pub runtime_paths: ExecServerRuntimePaths,
}

static ACTIVE_HOMES: OnceLock<Mutex<HashSet<PathBuf>>> = OnceLock::new();

struct SessionHomeGuard {
    home: PathBuf,
    has_auth: bool,
}

impl SessionHomeGuard {
    fn acquire(home: PathBuf) -> Result<Self> {
        let mut homes = ACTIVE_HOMES
            .get_or_init(Mutex::default)
            .lock()
            .map_err(|_| anyhow!("Codex home registry is unavailable"))?;
        ensure!(homes.insert(home.clone()), "Codex home is already in use");
        Ok(Self {
            home,
            has_auth: false,
        })
    }
}

impl Drop for SessionHomeGuard {
    fn drop(&mut self) {
        if self.has_auth {
            let _ = logout(
                &self.home,
                AuthCredentialsStoreMode::Ephemeral,
                AuthKeyringBackendKind::default(),
            );
        }
        if let Ok(mut homes) = ACTIVE_HOMES.get_or_init(Mutex::default).lock() {
            homes.remove(&self.home);
        }
    }
}

pub struct CodexSession {
    manager: ThreadManager,
    thread_id: ThreadId,
    thread: Arc<CodexThread>,
    _home_guard: SessionHomeGuard,
}

impl CodexSession {
    pub async fn start(options: SessionOptions) -> Result<Self> {
        let url = Url::parse(&options.base_url).context("invalid model service URL")?;
        let local = matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "::1"));
        ensure!(
            url.scheme() == "https" || (url.scheme() == "http" && local),
            "model service must use HTTPS or loopback HTTP"
        );
        ensure!(
            url.username().is_empty()
                && url.password().is_none()
                && url.query().is_none()
                && url.fragment().is_none(),
            "model service URL cannot contain credentials, query, or fragment"
        );
        ensure!(!options.model.trim().is_empty(), "model ID is required");
        let project = options
            .project_root
            .canonicalize()
            .context("resolve project root")?;
        ensure!(project.is_dir(), "project root is not a directory");
        std::fs::create_dir_all(&options.codex_home).context("create ShipiOS Codex home")?;
        let home = options.codex_home.canonicalize()?;
        let mut home_guard = SessionHomeGuard::acquire(home.clone())?;
        let mut config =
            Config::load_default_with_cli_overrides_for_codex_home(home.clone(), Vec::new())
                .await?;
        config.cwd = AbsolutePathBuf::from_absolute_path_checked(project.clone())?;
        config.workspace_roots = vec![config.cwd.clone()];
        config.workspace_roots_explicit = true;
        config.model = Some(options.model);
        config.cli_auth_credentials_store_mode = AuthCredentialsStoreMode::Ephemeral;
        config.permissions = Permissions::from_approval_and_profile(
            Constrained::allow_any(AskForApproval::Never),
            Constrained::allow_any(PermissionProfile::read_only()),
        )?;

        let mut provider = config.model_provider.clone();
        provider.name = "ShipiOS API".to_owned();
        provider.base_url = Some(url.as_str().trim_end_matches('/').to_owned());
        provider.env_key = None;
        provider.experimental_bearer_token = None;
        provider.auth = None;
        provider.aws = None;
        provider.requires_openai_auth = options.api_key.as_ref().is_some_and(|key| !key.is_empty());
        provider.supports_websockets = false;
        provider.supports_standalone_web_search = false;
        config.model_provider_id = "shipios-api".to_owned();
        config
            .model_providers
            .insert("shipios-api".to_owned(), provider.clone());
        config.model_provider = provider;

        if let Some(key) = options.api_key.as_deref().filter(|key| !key.is_empty()) {
            login_with_api_key(
                &home,
                key,
                AuthCredentialsStoreMode::Ephemeral,
                AuthKeyringBackendKind::default(),
            )?;
            home_guard.has_auth = true;
        }
        let state_db = init_state_db(&config).await;
        let auth_manager = AuthManager::shared_from_config(&config, false).await?;
        let thread_store = thread_store_from_config(&config, state_db.clone());
        let environment_manager = Arc::new(
            EnvironmentManager::from_codex_home(
                config.codex_home.clone(),
                Some(options.runtime_paths),
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
            Arc::new(ExtensionRegistryBuilder::<Config>::new().build()),
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
            thread_id, thread, ..
        } = manager
            .start_thread(StartThreadOptions::new(config))
            .await?;
        Ok(Self {
            manager,
            thread_id,
            thread,
            _home_guard: home_guard,
        })
    }

    pub fn thread_id(&self) -> String {
        self.thread_id.to_string()
    }

    pub fn rollout_path(&self) -> Option<PathBuf> {
        self.thread.rollout_path()
    }

    pub async fn submit_text(&self, text: String) -> Result<String> {
        ensure!(!text.trim().is_empty(), "message is empty");
        let result = self
            .thread
            .start_turn_if_idle(TurnInputRequest::user_input(vec![UserInput::Text {
                text,
                text_elements: Vec::new(),
            }]))
            .await?;
        match result {
            StartIfIdleSubmission::Started { turn_id } => Ok(turn_id),
            StartIfIdleSubmission::NotSubmitted { reason } => {
                bail!("turn was not submitted: {reason:?}")
            }
        }
    }

    pub async fn next_event(&self) -> Result<EventMsg> {
        Ok(self.thread.next_event().await?.msg)
    }

    pub async fn shutdown(mut self) -> Result<()> {
        let result = self.thread.shutdown_and_wait().await;
        self.manager.remove_thread(&self.thread_id).await;
        result.context("shut down Codex thread")?;
        if self._home_guard.has_auth {
            let removed = logout(
                &self._home_guard.home,
                AuthCredentialsStoreMode::Ephemeral,
                AuthKeyringBackendKind::default(),
            )?;
            ensure!(removed, "ephemeral model credential was not removed");
            self._home_guard.has_auth = false;
        }
        Ok(())
    }
}
