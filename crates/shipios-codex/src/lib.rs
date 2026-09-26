//! Host adapter for the pinned Codex Core runtime.

use anyhow::{Context, Result, anyhow, bail, ensure};
use codex_config::{McpServerConfig, RawMcpServerConfig};
use codex_core_api::{
    AbsolutePathBuf, AskForApproval, AuthCredentialsStoreMode, AuthKeyringBackendKind, AuthManager,
    CodexAppsToolsCache, CodexHomeUserInstructionsProvider, CodexThread, Config, Constrained,
    EnvironmentManager, EventMsg, ExecServerRuntimePaths, ExtensionRegistryBuilder, Feature,
    NewThread, Op, PermissionProfile, Permissions, SessionSource, StartIfIdleSubmission,
    StartThreadOptions, SteerSubmission, ThreadId, ThreadManager, TurnInputRequest, UserInput,
    build_models_manager, init_state_db, local_agent_graph_store_from_state_db,
    passthrough_image_store, resolve_installation_id, thread_store_from_config,
};
use codex_login::{login_with_api_key, logout};
use codex_protocol::approvals::ElicitationAction;
use codex_protocol::config_types::{
    CollaborationMode, ModeKind, Settings as CollaborationSettings,
};
use codex_protocol::mcp::{ClientMcpExtensions, RequestId};
use codex_protocol::openai_models::ReasoningEffort;
use codex_protocol::protocol::ReviewDecision;
use codex_protocol::protocol::ThreadSettingsOverrides;
use codex_protocol::request_user_input::{RequestUserInputAnswer, RequestUserInputResponse};
use serde::Deserialize;
use serde_json::json;
use std::{
    collections::{HashMap, HashSet},
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
    pub read_only: bool,
    pub mcp_servers: Vec<ShipMcpServer>,
    pub runtime_paths: ExecServerRuntimePaths,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShipMcpServer {
    pub name: String,
    pub enabled: bool,
    pub transport: ShipMcpTransport,
    pub command: String,
    pub arguments: Vec<String>,
    pub environment: Vec<ShipMcpKeyValue>,
    pub environment_passthrough: Vec<String>,
    pub working_directory: String,
    pub url: String,
    pub bearer_token_environment_variable: String,
    pub headers: Vec<ShipMcpKeyValue>,
    pub environment_headers: Vec<ShipMcpKeyValue>,
}

#[derive(Debug, Deserialize)]
pub enum ShipMcpTransport {
    #[serde(rename = "stdio")]
    Stdio,
    #[serde(rename = "streamableHTTP")]
    StreamableHttp,
}

#[derive(Debug, Deserialize)]
pub struct ShipMcpKeyValue {
    pub key: String,
    pub value: String,
}

fn mcp_key_values(entries: Vec<ShipMcpKeyValue>) -> Result<HashMap<String, String>> {
    let count = entries.len();
    let values = entries
        .into_iter()
        .map(|entry| (entry.key, entry.value))
        .collect::<HashMap<_, _>>();
    ensure!(values.len() == count, "duplicate MCP variable or header");
    Ok(values)
}

fn configured_mcp_servers(servers: Vec<ShipMcpServer>) -> Result<HashMap<String, McpServerConfig>> {
    ensure!(servers.len() <= 100, "too many MCP servers");
    let mut configured = HashMap::new();
    let mut names = HashSet::new();
    for server in servers.into_iter().filter(|server| server.enabled) {
        ensure!(
            !server.name.is_empty()
                && server.name.len() <= 64
                && server.name.as_bytes()[0].is_ascii_alphanumeric()
                && server
                    .name
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte)),
            "invalid MCP server name"
        );
        ensure!(
            names.insert(server.name.to_ascii_lowercase()),
            "duplicate MCP server name"
        );
        let raw = match server.transport {
            ShipMcpTransport::Stdio => json!({
                "command": server.command,
                "args": server.arguments,
                "env": mcp_key_values(server.environment)?,
                "env_vars": server.environment_passthrough,
                "cwd": if server.working_directory.is_empty() { None } else { Some(server.working_directory) },
            }),
            ShipMcpTransport::StreamableHttp => json!({
                "url": server.url,
                "bearer_token_env_var": if server.bearer_token_environment_variable.is_empty() { None } else { Some(server.bearer_token_environment_variable) },
                "http_headers": mcp_key_values(server.headers)?,
                "env_http_headers": mcp_key_values(server.environment_headers)?,
            }),
        };
        let raw: RawMcpServerConfig =
            serde_json::from_value(raw).context("parse ShipiOS MCP server")?;
        let config = McpServerConfig::try_from(raw).map_err(|error| anyhow!(error))?;
        configured.insert(server.name, config);
    }
    Ok(configured)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CodexTurnMode {
    Default,
    Plan,
    Goal(String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ApprovalDecision {
    Allow,
    AllowForSession,
    Deny,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ElicitationDecision {
    Accept,
    AcceptForSession,
    Decline,
    Cancel,
}

impl From<ApprovalDecision> for ReviewDecision {
    fn from(value: ApprovalDecision) -> Self {
        match value {
            ApprovalDecision::Allow => Self::Approved,
            ApprovalDecision::AllowForSession => Self::ApprovedForSession,
            ApprovalDecision::Deny => Self::Denied {
                rejection: "User denied this action in ShipiOS".to_owned(),
            },
        }
    }
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
    model: String,
    read_only: bool,
    _home_guard: SessionHomeGuard,
}

impl CodexSession {
    pub async fn start(options: SessionOptions) -> Result<Self> {
        Self::open(options, None).await
    }

    pub async fn resume(options: SessionOptions, rollout_path: PathBuf) -> Result<Self> {
        Self::open(options, Some(rollout_path)).await
    }

    async fn open(options: SessionOptions, rollout_path: Option<PathBuf>) -> Result<Self> {
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
        config.model = Some(options.model.clone());
        config.mcp_servers = Constrained::allow_any(configured_mcp_servers(options.mcp_servers)?);
        config.update_plan_enabled = true;
        config
            .features
            .enable(Feature::DefaultModeRequestUserInput)?;
        config.cli_auth_credentials_store_mode = AuthCredentialsStoreMode::Ephemeral;
        config.permissions = Permissions::from_approval_and_profile(
            Constrained::allow_any(AskForApproval::OnRequest),
            Constrained::allow_any(if options.read_only {
                PermissionProfile::read_only()
            } else {
                PermissionProfile::workspace_write()
            }),
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
            build_models_manager(&config, Arc::clone(&auth_manager)),
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
        } = match rollout_path {
            Some(path) => {
                manager
                    .resume_thread_from_rollout(
                        config,
                        path,
                        auth_manager,
                        None,
                        ClientMcpExtensions::default(),
                    )
                    .await?
            }
            None => {
                manager
                    .start_thread(StartThreadOptions::new(config))
                    .await?
            }
        };
        Ok(Self {
            manager,
            thread_id,
            thread,
            model: options.model,
            read_only: options.read_only,
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
        self.submit_inputs(vec![UserInput::Text {
            text,
            text_elements: Vec::new(),
        }])
        .await
    }

    pub async fn submit_inputs(&self, inputs: Vec<UserInput>) -> Result<String> {
        self.submit_inputs_in_mode(inputs, CodexTurnMode::Default, None, None)
            .await
    }

    pub async fn submit_inputs_in_mode(
        &self,
        inputs: Vec<UserInput>,
        mode: CodexTurnMode,
        model: Option<String>,
        reasoning_effort: Option<String>,
    ) -> Result<String> {
        ensure!(
            inputs.iter().any(|input| match input {
                UserInput::Text { text, .. } => !text.trim().is_empty(),
                UserInput::LocalImage { .. } | UserInput::Image { .. } => true,
                _ => false,
            }),
            "message is empty"
        );
        let kind = match &mode {
            CodexTurnMode::Default | CodexTurnMode::Goal(_) => ModeKind::Default,
            CodexTurnMode::Plan => ModeKind::Plan,
        };
        let preset = self
            .manager
            .list_collaboration_modes()
            .into_iter()
            .find(|item| item.mode == Some(kind))
            .ok_or_else(|| anyhow!("Codex collaboration mode is unavailable"))?;
        let model = model.unwrap_or_else(|| self.model.clone());
        let model = model.trim().to_owned();
        ensure!(!model.is_empty(), "model ID is required");
        let effort = reasoning_effort
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(|value| {
                value
                    .parse::<ReasoningEffort>()
                    .map_err(|error| anyhow!(error))
            })
            .transpose()?;
        let mut collaboration_mode = CollaborationMode {
            mode: kind,
            settings: CollaborationSettings {
                model: model.clone(),
                reasoning_effort: effort.clone(),
                developer_instructions: None,
            },
        }
        .apply_mask(&preset);
        collaboration_mode.settings.model = model;
        collaboration_mode.settings.reasoning_effort = effort;
        if let CodexTurnMode::Goal(instructions) = &mode {
            ensure!(
                !instructions.trim().is_empty(),
                "goal instructions are empty"
            );
            let base = collaboration_mode
                .settings
                .developer_instructions
                .get_or_insert_with(String::new);
            base.push_str("\n\n");
            base.push_str(instructions);
        }
        let settings = ThreadSettingsOverrides {
            collaboration_mode: Some(collaboration_mode),
            permission_profile: Some(if self.read_only || mode == CodexTurnMode::Plan {
                PermissionProfile::read_only()
            } else {
                PermissionProfile::workspace_write()
            }),
            ..Default::default()
        };
        let result = self
            .thread
            .start_turn_if_idle(TurnInputRequest::user_input(inputs).with_thread_settings(settings))
            .await?;
        match result {
            StartIfIdleSubmission::Started { turn_id } => Ok(turn_id),
            StartIfIdleSubmission::NotSubmitted { reason } => {
                bail!("turn was not submitted: {reason:?}")
            }
        }
    }

    pub async fn steer_inputs(
        &self,
        inputs: Vec<UserInput>,
        expected_turn_id: String,
    ) -> Result<bool> {
        ensure!(!expected_turn_id.is_empty(), "expected turn ID is empty");
        ensure!(
            inputs.iter().any(|input| match input {
                UserInput::Text { text, .. } => !text.trim().is_empty(),
                UserInput::LocalImage { .. } | UserInput::Image { .. } => true,
                _ => false,
            }),
            "message is empty"
        );
        match self
            .thread
            .steer_turn(TurnInputRequest::user_input(inputs), expected_turn_id)
            .await?
        {
            SteerSubmission::Steered { .. } => Ok(true),
            SteerSubmission::NotSubmitted { .. } => Ok(false),
        }
    }

    pub async fn next_event(&self) -> Result<EventMsg> {
        Ok(self.thread.next_event().await?.msg)
    }

    pub async fn interrupt_turn(&self) -> Result<()> {
        self.thread.submit(Op::Interrupt).await?;
        Ok(())
    }

    pub async fn approve_exec(
        &self,
        id: String,
        turn_id: Option<String>,
        decision: ApprovalDecision,
    ) -> Result<()> {
        self.thread
            .submit(Op::ExecApproval {
                id,
                turn_id,
                decision: decision.into(),
            })
            .await?;
        Ok(())
    }

    pub async fn approve_patch(&self, id: String, decision: ApprovalDecision) -> Result<()> {
        self.thread
            .submit(Op::PatchApproval {
                id,
                decision: decision.into(),
            })
            .await?;
        Ok(())
    }

    pub async fn answer_user_input(
        &self,
        turn_id: String,
        answers: HashMap<String, Vec<String>>,
    ) -> Result<()> {
        let response = RequestUserInputResponse {
            answers: answers
                .into_iter()
                .map(|(id, answers)| (id, RequestUserInputAnswer { answers }))
                .collect(),
        };
        self.thread
            .submit(Op::UserInputAnswer {
                id: turn_id,
                response,
            })
            .await?;
        Ok(())
    }

    pub async fn resolve_mcp_elicitation(
        &self,
        server_name: String,
        request_id: RequestId,
        decision: ElicitationDecision,
        form_content: Option<serde_json::Value>,
    ) -> Result<()> {
        let (action, content, meta) = match decision {
            ElicitationDecision::Accept => (
                ElicitationAction::Accept,
                Some(form_content.unwrap_or_else(|| json!({}))),
                None,
            ),
            ElicitationDecision::AcceptForSession => (
                ElicitationAction::Accept,
                Some(json!({})),
                Some(json!({"persist": "session"})),
            ),
            ElicitationDecision::Decline => (ElicitationAction::Decline, None, None),
            ElicitationDecision::Cancel => (ElicitationAction::Cancel, None, None),
        };
        self.thread
            .submit(Op::ResolveElicitation {
                server_name,
                request_id,
                decision: action,
                content,
                meta,
            })
            .await?;
        Ok(())
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn approval_choices_match_pinned_codex_protocol() {
        assert_eq!(
            serde_json::to_value(ReviewDecision::from(ApprovalDecision::Allow)).unwrap(),
            serde_json::json!("approved")
        );
        assert_eq!(
            serde_json::to_value(ReviewDecision::from(ApprovalDecision::AllowForSession)).unwrap(),
            serde_json::json!("approved_for_session")
        );
        assert!(matches!(
            ReviewDecision::from(ApprovalDecision::Deny),
            ReviewDecision::Denied { .. }
        ));
    }
}
