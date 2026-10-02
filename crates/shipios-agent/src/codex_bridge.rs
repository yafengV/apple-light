use anyhow::{Context, Result, anyhow, ensure};
use codex_core_api::UserInput;
use codex_protocol::mcp::RequestId;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use shipios_codex::{
    ApprovalDecision, BrowserToolBridge, CodexSession, CodexTurnMode, ElicitationDecision,
    SessionOptions, SessionPermissions, SessionResponsePreferences, SessionWebSearch,
    ShipMcpServer,
};
use shipios_core::config::private_dir;
use std::{collections::HashMap, io::Write, path::PathBuf, sync::Arc};
use tokio::sync::{Mutex, broadcast, mpsc, oneshot};
use uuid::Uuid;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StartThread {
    pub task_id: String,
    pub base_url: String,
    pub model: String,
    pub api_key: Option<String>,
    pub initial_context_bytes: Option<usize>,
    #[serde(default)]
    pub resume_only: bool,
    #[serde(default)]
    pub read_only: bool,
    #[serde(default)]
    pub text_only: bool,
    #[serde(default)]
    pub additional_folders: Vec<PathBuf>,
    #[serde(default)]
    pub permissions: SessionPermissions,
    #[serde(default)]
    pub permissions_selection_explicit: bool,
    #[serde(default)]
    pub permission_profile_id: Option<String>,
    #[serde(default)]
    pub permission_profile_config: Option<String>,
    #[serde(default)]
    pub permission_profile_selection_explicit: bool,
    #[serde(default)]
    pub responses: SessionResponsePreferences,
    #[serde(default)]
    pub web_search: SessionWebSearch,
    #[serde(default)]
    pub mcp_servers: Vec<ShipMcpServer>,
    #[serde(default)]
    pub confetti_enabled: bool,
    pub fork_origin: Option<ForkThreadOrigin>,
    pub resume_origin: Option<ResumeThreadOrigin>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ForkThreadOrigin {
    pub task_id: String,
    pub workspace: PathBuf,
    pub thread_id: String,
    pub through_turn_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ResumeThreadOrigin {
    pub workspace: PathBuf,
    pub thread_id: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadInfo {
    pub task_id: String,
    pub thread_id: String,
    pub resumed: bool,
    pub forked: bool,
    pub history_workspace: Option<PathBuf>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PersistedThread {
    thread_id: String,
    rollout_path: PathBuf,
    #[serde(default)]
    permissions: SessionPermissions,
    #[serde(default)]
    permission_profile_id: Option<String>,
    #[serde(default)]
    responses: SessionResponsePreferences,
    #[serde(default)]
    web_search: SessionWebSearch,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CodexImage {
    id: String,
    file_extension: String,
    byte_count: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CodexTextAttachment {
    id: String,
    byte_count: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CodexSubmit {
    pub task_id: String,
    pub text: String,
    #[serde(default)]
    pub images: Vec<CodexImage>,
    pub text_attachment: Option<CodexTextAttachment>,
    #[serde(default)]
    pub plan_mode: bool,
    pub goal_instructions: Option<String>,
    pub model: Option<String>,
    pub reasoning_effort: Option<String>,
    #[serde(default)]
    pub permissions: Option<SessionPermissions>,
}

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodexApprovalKind {
    Exec,
    Patch,
}

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodexApprovalChoice {
    Allow,
    AllowForSession,
    Deny,
}

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodexElicitationChoice {
    Allow,
    AllowForSession,
    Deny,
    Cancel,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CodexApproval {
    pub task_id: String,
    pub id: String,
    pub turn_id: Option<String>,
    pub kind: CodexApprovalKind,
    pub decision: CodexApprovalChoice,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CodexElicitation {
    pub task_id: String,
    pub server_name: String,
    pub request_id: RequestId,
    pub decision: CodexElicitationChoice,
    #[serde(default)]
    pub content: Option<Value>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CodexUserInputAnswer {
    pub task_id: String,
    pub turn_id: String,
    pub answers: HashMap<String, Vec<String>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CodexBrowserResolution {
    pub task_id: String,
    pub request_id: String,
    pub result: Value,
}

fn saved_thread(home: &std::path::Path) -> Result<Option<PersistedThread>> {
    let path = home.join("thread.json");
    if path.exists() {
        ensure!(
            path.canonicalize()?.starts_with(home.canonicalize()?),
            "saved Codex reference escaped its private home"
        );
    }
    let data = match std::fs::read(&path) {
        Ok(data) => data,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error).context("read saved Codex thread"),
    };
    let thread: PersistedThread =
        serde_json::from_slice(&data).context("parse saved Codex thread")?;
    let home = home.canonicalize().context("resolve private Codex home")?;
    let rollout = thread
        .rollout_path
        .canonicalize()
        .context("saved Codex rollout is missing")?;
    ensure!(
        rollout.starts_with(&home),
        "saved Codex rollout escaped its private home"
    );
    Ok(Some(PersistedThread {
        thread_id: thread.thread_id,
        rollout_path: rollout,
        permissions: thread.permissions,
        permission_profile_id: thread.permission_profile_id,
        responses: thread.responses,
        web_search: thread.web_search,
    }))
}

fn persist_thread(home: &std::path::Path, thread: &PersistedThread) -> Result<()> {
    ensure!(
        thread.rollout_path.starts_with(home),
        "Codex rollout escaped its private home"
    );
    let temporary = home.join(format!("thread-{}.tmp", Uuid::new_v4()));
    std::fs::write(&temporary, serde_json::to_vec(thread)?)
        .context("save Codex thread reference")?;
    if let Err(error) = std::fs::rename(&temporary, home.join("thread.json")) {
        let _ = std::fs::remove_file(&temporary);
        return Err(error).context("publish Codex thread reference");
    }
    Ok(())
}

fn copy_permission_config_for_fork(
    source_home: &std::path::Path,
    home: &std::path::Path,
) -> Result<()> {
    let source_path = source_home.join("config.toml");
    ensure!(
        source_path.canonicalize()?.starts_with(source_home),
        "source permission config escaped its private home"
    );
    let source_config =
        std::fs::read(&source_path).context("read source private permission config")?;
    let target_config = home.join("config.toml");
    match std::fs::read(&target_config) {
        Ok(existing) => {
            ensure!(
                target_config.canonicalize()?.starts_with(home),
                "fork permission config escaped its private home"
            );
            ensure!(
                existing == source_config,
                "fork permission config differs from source"
            );
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&target_config)
                .context("create private permission config for fork")?
                .write_all(&source_config)
                .context("copy private permission config for fork")?;
        }
        Err(error) => return Err(error).context("read fork private permission config"),
    }
    Ok(())
}

fn write_private_permission_config(home: &std::path::Path, source: &str) -> Result<()> {
    use std::os::unix::fs::OpenOptionsExt;

    let path = home.join("config.toml");
    match std::fs::symlink_metadata(&path) {
        Ok(metadata) => {
            ensure!(
                metadata.file_type().is_file(),
                "private permission config is not a regular file"
            );
            if std::fs::read_to_string(&path)? == source {
                return Ok(());
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error).context("inspect private permission config"),
    }
    let staged = home.join(format!("config-{}.tmp", Uuid::new_v4()));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&staged)
        .context("stage private permission config")?;
    if let Err(error) = file
        .write_all(source.as_bytes())
        .and_then(|()| file.sync_all())
    {
        let _ = std::fs::remove_file(&staged);
        return Err(error).context("write private permission config");
    }
    if let Err(error) = std::fs::rename(&staged, &path) {
        let _ = std::fs::remove_file(&staged);
        return Err(error).context("install private permission config");
    }
    Ok(())
}

enum Command {
    Submit {
        inputs: Vec<UserInput>,
        mode: CodexTurnMode,
        model: Option<String>,
        reasoning_effort: Option<String>,
        permissions: Option<SessionPermissions>,
        reply: oneshot::Sender<Result<String>>,
    },
    Compact(oneshot::Sender<Result<()>>),
    Steer(Vec<UserInput>, String, oneshot::Sender<Result<bool>>),
    Approve(CodexApproval, oneshot::Sender<Result<()>>),
    ResolveElicitation(CodexElicitation, oneshot::Sender<Result<()>>),
    Answer(CodexUserInputAnswer, oneshot::Sender<Result<()>>),
    Interrupt(oneshot::Sender<Result<()>>),
    Stop(oneshot::Sender<Result<()>>),
}

struct ThreadHandle {
    thread_id: String,
    sender: mpsc::Sender<Command>,
}

pub struct CodexBridge {
    data_dir: PathBuf,
    project: PathBuf,
    sessions: Arc<Mutex<HashMap<String, ThreadHandle>>>,
    events: broadcast::Sender<Value>,
    browser: BrowserToolBridge,
}

impl CodexBridge {
    fn fork_source(&self, origin: &ForkThreadOrigin, target: &str) -> Result<PersistedThread> {
        let source_id = Uuid::parse_str(&origin.task_id)
            .context("invalid fork source task")?
            .hyphenated()
            .to_string();
        ensure!(
            source_id != target,
            "a task cannot fork itself into the same identity"
        );
        ensure!(
            !origin.through_turn_id.is_empty() && origin.through_turn_id.len() <= 128,
            "invalid fork turn ID"
        );
        let (_, saved) = self.history_source(&source_id, &origin.workspace, &origin.thread_id)?;
        Ok(saved)
    }

    /// Resolve only this application's private task history. Execution cwd may change,
    /// but a resumed task retains its original namespace and native thread identity.
    fn history_source(
        &self,
        task_id: &str,
        source_workspace: &std::path::Path,
        thread_id: &str,
    ) -> Result<(PathBuf, PersistedThread)> {
        let source_id = Uuid::parse_str(task_id)?.hyphenated().to_string();
        let expected_thread = Uuid::parse_str(thread_id).context("invalid source thread")?;
        ensure!(
            source_workspace.is_absolute(),
            "source workspace must be absolute"
        );
        let workspace = match source_workspace.canonicalize() {
            Ok(workspace) => {
                ensure!(workspace.is_dir(), "source workspace is not a directory");
                Some(workspace)
            }
            // A pruned checkout does not remove its private rollout. The captured spelling
            // still identifies its project namespace; all private-home checks below remain.
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(error) => return Err(error).context("source workspace is unavailable"),
        };
        let project_data = if workspace.as_ref() == Some(&self.project.canonicalize()?) {
            self.data_dir.clone()
        } else {
            let projects = self
                .data_dir
                .parent()
                .context("private projects root is unavailable")?;
            ensure!(
                projects.file_name().is_some_and(|name| name == "Projects"),
                "cross-project history requires a private projects root"
            );
            let digest = format!(
                "{:x}",
                // Use the transport's captured spelling for its existing private directory.
                // macOS Foundation and Rust canonicalize /var vs /private/var differently.
                Sha256::digest(source_workspace.to_string_lossy().as_bytes())
            );
            projects.join(digest)
        };
        let home = project_data.join("Codex/Tasks").join(source_id);
        let canonical = home
            .canonicalize()
            .context("source Codex home is unavailable")?;
        if let Some(projects) = self.data_dir.parent() {
            ensure!(
                canonical.starts_with(projects.canonicalize()?),
                "source Codex project escaped its private root"
            );
        }
        ensure!(
            canonical.starts_with(project_data.canonicalize()?),
            "source Codex home escaped its project"
        );
        let saved = saved_thread(&canonical)?.context("source Codex history is unavailable")?;
        ensure!(
            Uuid::parse_str(&saved.thread_id)? == expected_thread,
            "source Codex thread identity changed"
        );
        Ok((canonical, saved))
    }

    pub fn new(data_dir: PathBuf, project: PathBuf) -> Self {
        let (events, _) = broadcast::channel(256);
        let screenshot_root = data_dir
            .parent()
            .and_then(std::path::Path::parent)
            .unwrap_or(&data_dir)
            .join("CodexBrowserStaging");
        let browser = BrowserToolBridge::new(events.clone(), screenshot_root);
        Self {
            data_dir,
            project,
            sessions: Arc::new(Mutex::new(HashMap::new())),
            events,
            browser,
        }
    }

    pub fn resolve_browser(&self, response: CodexBrowserResolution) -> Result<()> {
        ensure!(
            self.browser
                .resolve(&response.task_id, &response.request_id, response.result),
            "browser request is no longer pending for this task"
        );
        Ok(())
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Value> {
        self.events.subscribe()
    }

    pub async fn start(&self, request: StartThread) -> Result<ThreadInfo> {
        ensure!(
            !request.text_only
                || (request.resume_origin.is_none()
                    && request.fork_origin.is_none()
                    && !request.resume_only),
            "text generation cannot resume or fork a conversation"
        );
        let task_id = request.task_id;
        let task_key = Uuid::parse_str(&task_id)
            .context("taskId must be a UUID")?
            .hyphenated()
            .to_string();
        ensure!(
            !self.sessions.lock().await.contains_key(&task_key),
            "Codex thread already exists for task"
        );
        let history_workspace = request
            .resume_origin
            .as_ref()
            .map(|origin| origin.workspace.clone());
        let (home, previous) = if let Some(origin) = request.resume_origin.as_ref() {
            let (home, saved) =
                self.history_source(&task_key, &origin.workspace, &origin.thread_id)?;
            (home, Some(saved))
        } else {
            let home = private_dir(&self.data_dir.join("Codex"))?;
            let home = private_dir(&home.join("Tasks"))?;
            let home = private_dir(&home.join(&task_key))?
                .canonicalize()
                .context("resolve private Codex home")?;
            let previous = saved_thread(&home)?;
            (home, previous)
        };
        let fork_source = if previous.is_none() {
            request
                .fork_origin
                .as_ref()
                .map(|origin| self.fork_source(origin, &task_key))
                .transpose()?
        } else {
            None
        };
        ensure!(
            !request.resume_only || previous.is_some(),
            "Codex thread history is unavailable"
        );
        if previous.is_none() && fork_source.is_none() {
            ensure!(
                request
                    .initial_context_bytes
                    .is_none_or(|bytes| bytes <= 48_000),
                "conversation exceeds the 48 KiB Codex startup limit; start a new task"
            );
        }
        let runtime_paths = codex_core_api::ExecServerRuntimePaths::new(
            std::env::current_exe().context("resolve Agent executable")?,
            None,
        )?;
        let permissions = if request.permissions_selection_explicit {
            request.permissions
        } else {
            previous
                .as_ref()
                .or(fork_source.as_ref())
                .map(|thread| thread.permissions)
                .unwrap_or(request.permissions)
        };
        let responses = previous
            .as_ref()
            .or(fork_source.as_ref())
            .map(|thread| thread.responses)
            .unwrap_or(request.responses);
        let web_search = previous
            .as_ref()
            .or(fork_source.as_ref())
            .map(|thread| thread.web_search)
            .unwrap_or(request.web_search);
        let permission_profile_id = if request.permission_profile_selection_explicit {
            request.permission_profile_id.clone()
        } else {
            request.permission_profile_id.clone().or_else(|| {
                previous
                    .as_ref()
                    .or(fork_source.as_ref())
                    .and_then(|thread| thread.permission_profile_id.clone())
            })
        };
        ensure!(
            permission_profile_id.is_some() || request.permission_profile_config.is_none(),
            "permission config requires a selected profile"
        );
        if fork_source.is_some()
            && permission_profile_id.is_some()
            && request.permission_profile_config.is_none()
        {
            let origin = request.fork_origin.as_ref().expect("validated fork origin");
            let (source_home, _) =
                self.history_source(&origin.task_id, &origin.workspace, &origin.thread_id)?;
            copy_permission_config_for_fork(&source_home, &home)?;
        }
        if let (Some(id), Some(source)) = (
            permission_profile_id.as_deref(),
            request.permission_profile_config.as_deref(),
        ) {
            shipios_codex::validate_named_permission_config(source, id, &self.project).await?;
            write_private_permission_config(&home, source)?;
        }
        let options = SessionOptions {
            codex_home: home.clone(),
            project_root: self.project.clone(),
            additional_folders: request.additional_folders,
            base_url: request.base_url,
            model: request.model,
            api_key: request.api_key,
            read_only: request.read_only,
            permissions,
            permission_profile_id: permission_profile_id.clone(),
            responses,
            web_search,
            mcp_servers: request.mcp_servers,
            browser_bridge: Some(self.browser.for_task(task_id.clone())),
            confetti: request
                .confetti_enabled
                .then(|| (task_id.clone(), self.events.clone())),
            runtime_paths,
        };
        let resumed = previous.is_some();
        let forked = fork_source.is_some();
        ensure!(
            !request.text_only || previous.is_none(),
            "text generation requires a fresh identity"
        );
        let session = if request.text_only {
            CodexSession::start_text_generation(options).await?
        } else if let Some(ref previous) = previous {
            CodexSession::resume(options, previous.rollout_path.clone()).await?
        } else if let Some(ref source) = fork_source {
            let origin = request.fork_origin.as_ref().expect("validated fork origin");
            CodexSession::fork(
                options,
                source.rollout_path.clone(),
                source.thread_id.clone(),
                origin.through_turn_id.clone(),
            )
            .await?
        } else {
            CodexSession::start(options).await?
        };
        let thread_id = session.thread_id();
        if let Some(ref previous) = previous
            && previous.thread_id != thread_id
        {
            let _ = session.shutdown().await;
            return Err(anyhow!("resumed Codex thread identity changed"));
        }
        let saved = session.rollout_path().map(|rollout_path| PersistedThread {
            thread_id: thread_id.clone(),
            rollout_path,
            permissions,
            permission_profile_id,
            responses,
            web_search,
        });
        let save_result = saved
            .as_ref()
            .context("Codex thread has no persistent rollout")
            .and_then(|saved| persist_thread(&home, saved));
        if let Err(error) = save_result {
            let _ = session.shutdown().await;
            return Err(error);
        }
        let (sender, receiver) = mpsc::channel(16);
        let mut sessions = self.sessions.lock().await;
        ensure!(
            !sessions.contains_key(&task_key),
            "Codex thread already exists for task"
        );
        sessions.insert(
            task_key.clone(),
            ThreadHandle {
                thread_id: thread_id.clone(),
                sender,
            },
        );
        tokio::spawn(run_thread(
            session,
            receiver,
            Arc::clone(&self.sessions),
            self.events.clone(),
            task_key,
            task_id.clone(),
            thread_id.clone(),
        ));
        Ok(ThreadInfo {
            task_id,
            thread_id,
            resumed,
            forked,
            history_workspace,
        })
    }

    async fn sender(&self, task_id: &str) -> Result<mpsc::Sender<Command>> {
        let task_id = Uuid::parse_str(task_id).context("taskId must be a UUID")?;
        self.sessions
            .lock()
            .await
            .get(&task_id.hyphenated().to_string())
            .map(|handle| handle.sender.clone())
            .ok_or_else(|| anyhow!("Codex thread is not active"))
    }

    pub async fn approve(&self, approval: CodexApproval) -> Result<()> {
        ensure!(
            !approval.id.is_empty() && approval.id.len() <= 256,
            "invalid approval ID"
        );
        ensure!(
            !matches!(approval.kind, CodexApprovalKind::Patch)
                || !matches!(approval.decision, CodexApprovalChoice::AllowForSession),
            "patch approval does not support session grant"
        );
        let sender = self.sender(&approval.task_id).await?;
        let (reply, result) = oneshot::channel();
        sender
            .send(Command::Approve(approval, reply))
            .await
            .context("Codex thread stopped")?;
        result.await.context("Codex thread stopped")?
    }

    pub async fn resolve_elicitation(&self, response: CodexElicitation) -> Result<()> {
        ensure!(
            !response.server_name.is_empty() && response.server_name.len() <= 64,
            "invalid MCP server name"
        );
        if let RequestId::String(id) = &response.request_id {
            ensure!(!id.is_empty() && id.len() <= 256, "invalid elicitation ID");
        }
        if let Some(content) = &response.content {
            ensure!(
                serde_json::to_vec(content)?.len() <= 65_536,
                "elicitation content is too large"
            );
            ensure!(
                matches!(response.decision, CodexElicitationChoice::Allow),
                "only an accepted form may contain elicitation content"
            );
        }
        let sender = self.sender(&response.task_id).await?;
        let (reply, result) = oneshot::channel();
        sender
            .send(Command::ResolveElicitation(response, reply))
            .await
            .context("Codex thread stopped")?;
        result.await.context("Codex thread stopped")?
    }

    pub async fn answer_user_input(&self, answer: CodexUserInputAnswer) -> Result<()> {
        ensure!(
            !answer.turn_id.is_empty() && answer.turn_id.len() <= 256,
            "invalid turn ID"
        );
        ensure!(
            !answer.answers.is_empty() && answer.answers.len() <= 3,
            "invalid question count"
        );
        for (id, values) in &answer.answers {
            ensure!(!id.is_empty() && id.len() <= 128, "invalid question ID");
            ensure!(
                !values.is_empty() && values.len() <= 8,
                "invalid answer count"
            );
            ensure!(
                values
                    .iter()
                    .all(|value| !value.is_empty() && value.len() <= 4096),
                "invalid answer length"
            );
        }
        let sender = self.sender(&answer.task_id).await?;
        let (reply, result) = oneshot::channel();
        sender
            .send(Command::Answer(answer, reply))
            .await
            .context("Codex thread stopped")?;
        result.await.context("Codex thread stopped")?
    }

    #[cfg(test)]
    pub async fn submit(&self, task_id: &str, text: String) -> Result<String> {
        self.submit_with_images(task_id, text, Vec::new()).await
    }

    #[cfg(test)]
    pub async fn submit_with_images(
        &self,
        task_id: &str,
        text: String,
        images: Vec<CodexImage>,
    ) -> Result<String> {
        self.submit_with_attachments(CodexSubmit {
            task_id: task_id.to_owned(),
            text,
            images,
            text_attachment: None,
            plan_mode: false,
            goal_instructions: None,
            model: None,
            reasoning_effort: None,
            permissions: None,
        })
        .await
    }

    pub async fn submit_with_attachments(&self, request: CodexSubmit) -> Result<String> {
        let CodexSubmit {
            task_id,
            text,
            images,
            text_attachment,
            plan_mode,
            goal_instructions,
            model,
            reasoning_effort,
            permissions,
        } = request;
        ensure!(
            !plan_mode || goal_instructions.is_none(),
            "plan and goal modes cannot be combined"
        );
        let inputs = self.inputs_with_attachments(text, images, text_attachment)?;
        let (reply, result) = oneshot::channel();
        self.sender(&task_id)
            .await?
            .send(Command::Submit {
                inputs,
                mode: if let Some(instructions) = goal_instructions {
                    CodexTurnMode::Goal(instructions)
                } else if plan_mode {
                    CodexTurnMode::Plan
                } else {
                    CodexTurnMode::Default
                },
                model,
                reasoning_effort,
                permissions,
                reply,
            })
            .await
            .context("Codex thread stopped")?;
        result.await.context("Codex thread stopped")?
    }

    pub async fn compact(&self, task_id: &str) -> Result<()> {
        let (reply, result) = oneshot::channel();
        self.sender(task_id)
            .await?
            .send(Command::Compact(reply))
            .await
            .context("Codex thread stopped")?;
        result.await.context("Codex thread stopped")?
    }

    pub async fn steer_with_attachments(
        &self,
        task_id: &str,
        expected_turn_id: String,
        text: String,
        images: Vec<CodexImage>,
        text_attachment: Option<CodexTextAttachment>,
    ) -> Result<bool> {
        ensure!(
            !expected_turn_id.is_empty() && expected_turn_id.len() <= 256,
            "invalid expected turn ID"
        );
        let inputs = self.inputs_with_attachments(text, images, text_attachment)?;
        let (reply, result) = oneshot::channel();
        self.sender(task_id)
            .await?
            .send(Command::Steer(inputs, expected_turn_id, reply))
            .await
            .context("Codex thread stopped")?;
        result.await.context("Codex thread stopped")?
    }

    fn inputs_with_attachments(
        &self,
        mut text: String,
        images: Vec<CodexImage>,
        text_attachment: Option<CodexTextAttachment>,
    ) -> Result<Vec<UserInput>> {
        if let Some(attachment) = text_attachment {
            text.push_str(&self.read_staged_text(attachment)?);
        }
        ensure!(
            !text.trim().is_empty() || !images.is_empty(),
            "message is empty"
        );
        ensure!(text.chars().count() <= 1 << 20, "message text is too large");
        ensure!(images.len() <= 8, "too many images in one message");
        let mut inputs = vec![UserInput::Text {
            text,
            text_elements: Vec::new(),
        }];
        for image in images {
            inputs.push(UserInput::LocalImage {
                path: self.attachment_path(image)?,
                detail: None,
            });
        }
        Ok(inputs)
    }

    fn attachment_path(&self, image: CodexImage) -> Result<PathBuf> {
        Uuid::parse_str(&image.id).context("image ID must be a UUID")?;
        ensure!(
            matches!(
                image.file_extension.as_str(),
                "png" | "jpg" | "webp" | "gif"
            ),
            "unsupported image format"
        );
        ensure!(
            image.byte_count > 0 && image.byte_count <= 10 * 1024 * 1024,
            "image exceeds the 10 MiB limit"
        );
        let root = self
            .data_dir
            .parent()
            .and_then(std::path::Path::parent)
            .context("project data directory has no attachment root")?
            .canonicalize()
            .context("resolve attachment root")?;
        let attachments = root
            .join("Attachments")
            .canonicalize()
            .context("resolve attachments")?;
        ensure!(
            attachments.starts_with(&root),
            "attachments escaped data root"
        );
        let file = attachments.join(format!("{}.{}", image.id, image.file_extension));
        let metadata = file
            .symlink_metadata()
            .context("inspect image attachment")?;
        ensure!(
            metadata.file_type().is_file(),
            "image attachment is not a regular file"
        );
        ensure!(
            metadata.len() == image.byte_count,
            "image attachment size changed"
        );
        let resolved = file.canonicalize().context("resolve image attachment")?;
        ensure!(
            resolved.parent() == Some(attachments.as_path()),
            "image attachment escaped its directory"
        );
        Ok(resolved)
    }

    fn read_staged_text(&self, attachment: CodexTextAttachment) -> Result<String> {
        Uuid::parse_str(&attachment.id).context("text attachment ID must be a UUID")?;
        ensure!(
            attachment.byte_count > 0 && attachment.byte_count <= 1_000_000,
            "text attachment exceeds the 1 MB limit"
        );
        let root = self
            .data_dir
            .parent()
            .and_then(std::path::Path::parent)
            .context("project data directory has no attachment root")?
            .canonicalize()
            .context("resolve attachment root")?;
        let directory = root
            .join("CodexStaging")
            .canonicalize()
            .context("resolve text staging directory")?;
        ensure!(
            directory.starts_with(&root),
            "text staging escaped data root"
        );
        let file = directory.join(format!("{}.txt", attachment.id));
        let metadata = file.symlink_metadata().context("inspect staged text")?;
        ensure!(
            metadata.file_type().is_file(),
            "staged text is not a regular file"
        );
        ensure!(
            metadata.len() == attachment.byte_count,
            "staged text size changed"
        );
        let text = std::fs::read_to_string(&file).context("read staged text")?;
        std::fs::remove_file(&file).context("remove staged text")?;
        Ok(text)
    }

    pub async fn interrupt(&self, task_id: &str) -> Result<()> {
        self.browser.cancel_task(task_id);
        let (reply, result) = oneshot::channel();
        self.sender(task_id)
            .await?
            .send(Command::Interrupt(reply))
            .await
            .context("Codex thread stopped")?;
        result.await.context("Codex thread stopped")?
    }

    pub async fn stop(&self, task_id: &str) -> Result<()> {
        self.browser.cancel_task(task_id);
        let (reply, result) = oneshot::channel();
        self.sender(task_id)
            .await?
            .send(Command::Stop(reply))
            .await
            .context("Codex thread stopped")?;
        result.await.context("Codex thread stopped")?
    }

    pub async fn shutdown(&self) {
        let task_ids = self
            .sessions
            .lock()
            .await
            .keys()
            .cloned()
            .collect::<Vec<_>>();
        for task_id in task_ids {
            let _ =
                tokio::time::timeout(std::time::Duration::from_secs(10), self.stop(&task_id)).await;
        }
    }
}

async fn run_thread(
    session: CodexSession,
    mut receiver: mpsc::Receiver<Command>,
    sessions: Arc<Mutex<HashMap<String, ThreadHandle>>>,
    events: broadcast::Sender<Value>,
    task_key: String,
    task_id: String,
    thread_id: String,
) {
    let mut session = Some(session);
    while let Some(live) = session.as_ref() {
        tokio::select! {
            biased;
            command = receiver.recv() => match command {
                Some(Command::Submit { inputs, mode, model, reasoning_effort, permissions, reply }) => {
                    let _ = reply.send(live.submit_inputs_in_mode_with_permissions(
                        inputs, mode, model, reasoning_effort, permissions).await);
                }
                Some(Command::Compact(reply)) => {
                    let _ = reply.send(live.compact().await);
                }
                Some(Command::Steer(inputs, expected_turn_id, reply)) => {
                    let _ = reply.send(live.steer_inputs(inputs, expected_turn_id).await);
                }
                Some(Command::Approve(approval, reply)) => {
                    let decision = match approval.decision {
                        CodexApprovalChoice::Allow => ApprovalDecision::Allow,
                        CodexApprovalChoice::AllowForSession => ApprovalDecision::AllowForSession,
                        CodexApprovalChoice::Deny => ApprovalDecision::Deny,
                    };
                    let result = match approval.kind {
                        CodexApprovalKind::Exec => live.approve_exec(approval.id, approval.turn_id, decision).await,
                        CodexApprovalKind::Patch => live.approve_patch(approval.id, decision).await,
                    };
                    let _ = reply.send(result);
                }
                Some(Command::ResolveElicitation(response, reply)) => {
                    let decision = match response.decision {
                        CodexElicitationChoice::Allow => ElicitationDecision::Accept,
                        CodexElicitationChoice::AllowForSession => ElicitationDecision::AcceptForSession,
                        CodexElicitationChoice::Deny => ElicitationDecision::Decline,
                        CodexElicitationChoice::Cancel => ElicitationDecision::Cancel,
                    };
                    let result = live.resolve_mcp_elicitation(
                        response.server_name, response.request_id, decision, response.content).await;
                    let _ = reply.send(result);
                }
                Some(Command::Answer(answer, reply)) => {
                    let _ = reply.send(live.answer_user_input(answer.turn_id, answer.answers).await);
                }
                Some(Command::Interrupt(reply)) => {
                    let _ = reply.send(live.interrupt_turn().await);
                }
                Some(Command::Stop(reply)) => {
                    let _ = live.interrupt_turn().await;
                    let shutdown = session.take().expect("live session").shutdown().await;
                    let mut active = sessions.lock().await;
                    if active.get(&task_key).is_some_and(|handle| handle.thread_id == thread_id) {
                        active.remove(&task_key);
                    }
                    drop(active);
                    let _ = reply.send(shutdown);
                    break;
                }
                None => break,
            },
            event = live.next_event() => match event {
                Ok(event) => {
                    // Publish a terminal turn only after its complete rollout prefix is durable.
                    if matches!(event, codex_core_api::EventMsg::TurnComplete(_)
                        | codex_core_api::EventMsg::TurnAborted(_))
                        && let Err(error) = live.flush_rollout().await {
                            let _ = events.send(json!({"taskId":task_id,"threadId":thread_id,
                                "event":{"type":"error","message":error.to_string()}}));
                            break;
                    }
                    let _ = events.send(json!({
                        "taskId":task_id,"threadId":thread_id,"event":event
                    }));
                }
                Err(error) => {
                    let _ = events.send(json!({
                        "taskId":task_id,"threadId":thread_id,
                        "event":{"type":"error","message":error.to_string()}
                    }));
                    break;
                }
            }
        }
    }
    if let Some(live) = session {
        let _ = live.shutdown().await;
    }
    let mut active = sessions.lock().await;
    if active
        .get(&task_key)
        .is_some_and(|handle| handle.thread_id == thread_id)
    {
        active.remove(&task_key);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use codex_protocol::config_types::{ReasoningSummary, Verbosity, WebSearchMode};
    use serde_json::json;
    use shipios_codex::{SessionApprovalPolicy, SessionApprovalReviewer, SessionSandboxMode};
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[test]
    fn fork_copies_only_its_private_permission_config() -> Result<()> {
        let root = tempfile::tempdir()?;
        let source = root.path().join("source");
        let child = root.path().join("child");
        std::fs::create_dir_all(&source)?;
        std::fs::create_dir_all(&child)?;
        let source = source.canonicalize()?;
        let child = child.canonicalize()?;
        let contents = b"default_permissions = \"inspect\"\n";
        std::fs::write(source.join("config.toml"), contents)?;
        copy_permission_config_for_fork(&source, &child)?;
        assert_eq!(std::fs::read(child.join("config.toml"))?, contents);
        copy_permission_config_for_fork(&source, &child)?;
        std::fs::write(child.join("config.toml"), b"changed")?;
        assert!(copy_permission_config_for_fork(&source, &child).is_err());
        std::fs::remove_file(child.join("config.toml"))?;
        let outside = root.path().join("outside.toml");
        std::fs::write(&outside, contents)?;
        std::os::unix::fs::symlink(&outside, child.join("config.toml"))?;
        assert!(copy_permission_config_for_fork(&source, &child).is_err());
        Ok(())
    }

    #[test]
    fn private_permission_config_replaces_only_regular_task_file() -> Result<()> {
        let root = tempfile::tempdir()?;
        let home = root.path().join("task");
        std::fs::create_dir_all(&home)?;
        write_private_permission_config(&home, "first")?;
        write_private_permission_config(&home, "second")?;
        assert_eq!(std::fs::read_to_string(home.join("config.toml"))?, "second");
        std::fs::remove_file(home.join("config.toml"))?;
        let outside = root.path().join("outside.toml");
        std::fs::write(&outside, "untouched")?;
        std::os::unix::fs::symlink(&outside, home.join("config.toml"))?;
        assert!(write_private_permission_config(&home, "third").is_err());
        assert_eq!(std::fs::read_to_string(outside)?, "untouched");
        Ok(())
    }

    #[test]
    fn named_permission_profile_survives_agent_thread_start() -> Result<()> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_stack_size(16 * 1024 * 1024)
            .build()?;
        runtime.block_on(async {
            tokio::spawn(async move {
                let root = tempfile::tempdir()?;
                let project = root.path().join("Project");
                let data_dir = root.path().join("Data/Projects/fixture");
                let task_id = Uuid::new_v4().to_string();
                let home = data_dir.join("Codex/Tasks").join(&task_id);
                std::fs::create_dir_all(&project)?;
                let bridge = CodexBridge::new(data_dir, project);
                let info = bridge.start(StartThread {
                    task_id: task_id.clone(),
                    base_url: "http://127.0.0.1:1/v1".to_owned(),
                    model: "gpt-5.4".to_owned(),
                    api_key: None,
                    initial_context_bytes: Some(0),
                    resume_only: false,
                    read_only: false,
                    text_only: false,
                    additional_folders: Vec::new(),
                    permissions: SessionPermissions::default(),
                    permissions_selection_explicit: false,
                    permission_profile_id: Some("inspect".to_owned()),
                    permission_profile_config: Some("default_permissions = \"inspect\"\n[permissions.inspect]\nextends = \":read-only\"\n".to_owned()),
                    permission_profile_selection_explicit: true,
                    responses: SessionResponsePreferences::default(),
                    web_search: SessionWebSearch::default(),
                    mcp_servers: Vec::new(),
                    confetti_enabled: false,
                    fork_origin: None,
                    resume_origin: None,
                }).await?;
                assert_eq!(info.task_id, task_id);
                bridge.submit(&task_id, "Inspect this project".to_owned()).await?;
                bridge.shutdown().await;
                assert_eq!(saved_thread(&home)?.unwrap().permission_profile_id.as_deref(),
                    Some("inspect"));
                let resumed = bridge.start(StartThread {
                    task_id: task_id.clone(),
                    base_url: "http://127.0.0.1:1/v1".to_owned(),
                    model: "gpt-5.4".to_owned(),
                    api_key: None,
                    initial_context_bytes: Some(0),
                    resume_only: true,
                    read_only: false,
                    text_only: false,
                    additional_folders: Vec::new(),
                    permissions: SessionPermissions::default(),
                    permissions_selection_explicit: false,
                    permission_profile_id: None,
                    permission_profile_config: None,
                    permission_profile_selection_explicit: false,
                    responses: SessionResponsePreferences::default(),
                    web_search: SessionWebSearch::default(),
                    mcp_servers: Vec::new(),
                    confetti_enabled: false,
                    fork_origin: None,
                    resume_origin: None,
                }).await?;
                assert!(resumed.resumed);
                assert_eq!(saved_thread(&home)?.unwrap().permission_profile_id.as_deref(),
                    Some("inspect"));
                bridge.shutdown().await;
                let switched = bridge.start(StartThread {
                    task_id: task_id.clone(),
                    base_url: "http://127.0.0.1:1/v1".to_owned(),
                    model: "gpt-5.4".to_owned(),
                    api_key: None,
                    initial_context_bytes: Some(0),
                    resume_only: true,
                    read_only: false,
                    text_only: false,
                    additional_folders: Vec::new(),
                    permissions: SessionPermissions {
                        sandbox_mode: SessionSandboxMode::ReadOnly,
                        ..SessionPermissions::default()
                    },
                    permissions_selection_explicit: true,
                    permission_profile_id: None,
                    permission_profile_config: None,
                    permission_profile_selection_explicit: true,
                    responses: SessionResponsePreferences::default(),
                    web_search: SessionWebSearch::default(),
                    mcp_servers: Vec::new(),
                    confetti_enabled: false,
                    fork_origin: None,
                    resume_origin: None,
                }).await?;
                assert!(switched.resumed);
                assert_eq!(saved_thread(&home)?.unwrap().permission_profile_id, None);
                assert_eq!(saved_thread(&home)?.unwrap().permissions.sandbox_mode,
                    SessionSandboxMode::ReadOnly);
                bridge.shutdown().await;
                Ok::<_, anyhow::Error>(())
            }).await.context("named profile Agent worker failed")?
        })
    }

    #[test]
    fn turn_submit_accepts_current_permission_choice_and_legacy_requests() -> Result<()> {
        let base = json!({"taskId":"task", "text":"inspect", "images":[],
            "planMode":false});
        let legacy: CodexSubmit = serde_json::from_value(base.clone())?;
        assert_eq!(legacy.permissions, None);
        let mut current = base;
        current["permissions"] = json!({"approvalPolicy":"on-request",
            "approvalReviewer":"auto_review",
            "sandboxMode":"read-only", "networkAccess":false});
        let parsed: CodexSubmit = serde_json::from_value(current)?;
        assert_eq!(
            parsed.permissions,
            Some(SessionPermissions {
                approval_policy: SessionApprovalPolicy::OnRequest,
                approval_reviewer: SessionApprovalReviewer::AutoReview,
                sandbox_mode: SessionSandboxMode::ReadOnly,
                network_access: false,
            })
        );
        Ok(())
    }

    #[test]
    fn fork_source_validates_project_thread_and_private_reference() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let target = temp.path().join("Target");
        let source = temp.path().join("Source");
        std::fs::create_dir_all(&target)?;
        std::fs::create_dir_all(&source)?;
        let source = source.canonicalize()?;
        let projects = temp.path().join("Data/Projects");
        let target_data = projects.join("target");
        std::fs::create_dir_all(&target_data)?;
        let digest = format!("{:x}", Sha256::digest(source.to_string_lossy().as_bytes()));
        let project_data = projects.join(digest);
        let task_id = Uuid::new_v4().to_string();
        let home = project_data.join("Codex/Tasks").join(&task_id);
        std::fs::create_dir_all(&home)?;
        let home = home.canonicalize()?;
        let rollout = home.join("rollout.jsonl");
        std::fs::write(&rollout, "{}\n")?;
        let saved = PersistedThread {
            thread_id: Uuid::new_v4().to_string(),
            rollout_path: rollout,
            permissions: SessionPermissions::default(),
            permission_profile_id: None,
            responses: SessionResponsePreferences::default(),
            web_search: SessionWebSearch::default(),
        };
        persist_thread(&home, &saved)?;
        let bridge = CodexBridge::new(target_data, target);
        let mut origin = ForkThreadOrigin {
            task_id: task_id.clone(),
            workspace: source,
            thread_id: saved.thread_id.clone(),
            through_turn_id: "turn".to_owned(),
        };
        let child = Uuid::new_v4().to_string();
        assert_eq!(
            bridge.fork_source(&origin, &child)?.thread_id,
            saved.thread_id
        );
        assert!(bridge.fork_source(&origin, &task_id).is_err());
        // Same-identity resume is distinct from a fork: the task key is supplied by StartThread.
        let (resume_home, resumed) =
            bridge.history_source(&task_id, &origin.workspace, &origin.thread_id)?;
        assert_eq!(resume_home, home);
        assert_eq!(resumed.thread_id, saved.thread_id);
        assert!(
            bridge
                .history_source(&child, &origin.workspace, &origin.thread_id)
                .is_err()
        );
        assert!(
            bridge
                .history_source(&task_id, &origin.workspace, &child)
                .is_err()
        );
        let alias = temp.path().join("SourceAlias");
        std::os::unix::fs::symlink(&origin.workspace, &alias)?;
        let alias_digest = format!("{:x}", Sha256::digest(alias.to_string_lossy().as_bytes()));
        let alias_home = projects
            .join(alias_digest)
            .join("Codex/Tasks")
            .join(&task_id);
        std::fs::create_dir_all(&alias_home)?;
        let alias_rollout = alias_home.join("rollout.jsonl");
        std::fs::write(&alias_rollout, "{}\n")?;
        persist_thread(
            &alias_home,
            &PersistedThread {
                thread_id: saved.thread_id.clone(),
                rollout_path: alias_rollout,
                permissions: saved.permissions,
                permission_profile_id: saved.permission_profile_id.clone(),
                responses: saved.responses,
                web_search: saved.web_search,
            },
        )?;
        let alias_origin = ForkThreadOrigin {
            workspace: alias,
            task_id: task_id.clone(),
            thread_id: saved.thread_id.clone(),
            through_turn_id: "turn".to_owned(),
        };
        assert_eq!(
            bridge.fork_source(&alias_origin, &child)?.thread_id,
            saved.thread_id
        );
        std::fs::remove_dir_all(&origin.workspace)?;
        assert_eq!(
            bridge.fork_source(&origin, &child)?.thread_id,
            saved.thread_id
        );
        assert_eq!(
            bridge.fork_source(&alias_origin, &child)?.thread_id,
            saved.thread_id
        );
        let unowned = ForkThreadOrigin {
            workspace: temp.path().join("NeverOwnedWorkspace"),
            task_id: task_id.clone(),
            thread_id: saved.thread_id.clone(),
            through_turn_id: "turn".to_owned(),
        };
        assert!(bridge.fork_source(&unowned, &child).is_err());
        let standalone = CodexBridge::new(temp.path().join("Standalone"), bridge.project.clone());
        assert!(standalone.fork_source(&origin, &child).is_err());
        std::fs::write(&origin.workspace, "replaced with a file")?;
        assert!(bridge.fork_source(&origin, &child).is_err());
        std::fs::remove_file(&origin.workspace)?;
        origin.thread_id = Uuid::new_v4().to_string();
        assert!(bridge.fork_source(&origin, &child).is_err());
        origin.thread_id = saved.thread_id;
        let outside_reference = temp.path().join("outside-reference.json");
        std::fs::copy(home.join("thread.json"), &outside_reference)?;
        std::fs::remove_file(home.join("thread.json"))?;
        std::os::unix::fs::symlink(outside_reference, home.join("thread.json"))?;
        assert!(bridge.fork_source(&origin, &child).is_err());
        std::fs::remove_file(home.join("thread.json"))?;
        persist_thread(
            &home,
            &PersistedThread {
                thread_id: origin.thread_id.clone(),
                ..saved
            },
        )?;
        let outside_project = temp.path().join("OutsideProject");
        std::fs::rename(&project_data, &outside_project)?;
        std::os::unix::fs::symlink(outside_project, &project_data)?;
        assert!(bridge.fork_source(&origin, &child).is_err());
        Ok(())
    }

    #[test]
    fn model_browser_call_roundtrips_through_host_resolution() -> Result<()> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_stack_size(16 * 1024 * 1024)
            .build()?;
        runtime.block_on(async {
            tokio::spawn(async move {
                let server = MockServer::start().await;
                let sse = |events: Vec<Value>| {
                    events
                        .into_iter()
                        .map(|event| {
                            format!(
                                "event: {}\ndata: {event}\n\n",
                                event["type"].as_str().unwrap()
                            )
                        })
                        .collect::<String>()
                };
                let completed = |id: &str| {
                    json!({"type":"response.completed","response":{
                    "id":id,"usage":{"input_tokens":0,"input_tokens_details":null,
                    "output_tokens":0,"output_tokens_details":null,"total_tokens":0}}})
                };
                let call = sse(vec![
                    json!({"type":"response.created","response":{"id":"browser-1"}}),
                    json!({"type":"response.output_item.done","item":{
                        "type":"function_call","call_id":"browser-call-1",
                        "name":"shipios_browser","arguments":format!(
                            "{{\"action\":\"fill\",\"tab_id\":\"{}\",\"handle\":\"scan:1\",\"text\":\"sample\"}}",
                            Uuid::nil())}}),
                    completed("browser-1"),
                ]);
                let done = sse(vec![
                    json!({"type":"response.created","response":{"id":"browser-2"}}),
                    json!({"type":"response.output_item.done","item":{
                        "type":"message","role":"assistant","id":"browser-answer",
                        "content":[{"type":"output_text","text":"Found the page"}]}}),
                    completed("browser-2"),
                ]);
                let screenshot_call = sse(vec![
                    json!({"type":"response.created","response":{"id":"browser-shot"}}),
                    json!({"type":"response.output_item.done","item":{
                        "type":"function_call","call_id":"browser-call-shot",
                        "name":"shipios_browser","arguments":format!(
                            "{{\"action\":\"screenshot\",\"tab_id\":\"{}\"}}", Uuid::nil())}}),
                    completed("browser-shot"),
                ]);
                let download_call = sse(vec![
                    json!({"type":"response.created","response":{"id":"browser-download"}}),
                    json!({"type":"response.output_item.done","item":{
                        "type":"function_call","call_id":"browser-call-download",
                        "name":"shipios_browser","arguments":format!(
                            "{{\"action\":\"download\",\"tab_id\":\"{}\",\"handle\":\"scan:2\"}}", Uuid::nil())}}),
                    completed("browser-download"),
                ]);
                let site_tool_call = sse(vec![
                    json!({"type":"response.created","response":{"id":"browser-site-tool"}}),
                    json!({"type":"response.output_item.done","item":{
                        "type":"function_call","call_id":"browser-call-site-tool",
                        "name":"shipios_browser","arguments":format!(
                            "{{\"action\":\"site_tool_call\",\"tab_id\":\"{}\",\"site_tool\":\"read_title\",\"arguments\":{{\"section\":\"intro\"}}}}",
                            Uuid::nil())}}),
                    completed("browser-site-tool"),
                ]);
                let request_count = std::sync::atomic::AtomicUsize::new(0);
                Mock::given(method("POST"))
                    .and(path("/v1/responses"))
                    .respond_with(move |_request: &wiremock::Request| {
                        let number = request_count.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                        let response = match number {
                            0 => &call, 1 => &screenshot_call, 2 => &download_call,
                            3 => &site_tool_call, _ => &done,
                        };
                        ResponseTemplate::new(200)
                            .insert_header("content-type", "text/event-stream")
                            .set_body_string(response.clone())
                    })
                    .expect(5)
                    .mount(&server)
                    .await;
                let temp = tempfile::tempdir()?;
                let project = temp.path().join("Project");
                std::fs::create_dir_all(&project)?;
                let data_root = temp.path().join("Data");
                let project_data = data_root.join("Projects/fixture");
                std::fs::create_dir_all(&project_data)?;
                let bridge = CodexBridge::new(project_data, project);
                let mut events = bridge.subscribe();
                let task_id = Uuid::new_v4().to_string();
                bridge
                    .start(StartThread {
                        task_id: task_id.clone(),
                        base_url: format!("{}/v1", server.uri()),
                        model: "gpt-5.4".to_owned(),
                        api_key: None,
                        initial_context_bytes: Some(0),
                        resume_only: false,
                        fork_origin: None,
                        resume_origin: None,
                        read_only: false,
                        text_only: false,
                        additional_folders: Vec::new(),
                        permissions: SessionPermissions::default(),
                        permissions_selection_explicit: false,
                        permission_profile_id: None,
                        permission_profile_config: None,
                        permission_profile_selection_explicit: false,
                        responses: SessionResponsePreferences::default(),
                        web_search: SessionWebSearch::default(),
                        mcp_servers: Vec::new(),
                        confetti_enabled: false,
                    })
                    .await?;
                bridge
                    .submit(&task_id, "Fill the browser form".to_owned())
                    .await?;
                let mut saw_request = false;
                let mut saw_screenshot = false;
                let mut saw_download = false;
                let mut saw_site_tool = false;
                let mut saw_reply = false;
                loop {
                    let payload =
                        tokio::time::timeout(std::time::Duration::from_secs(15), events.recv())
                            .await??;
                    let event = &payload["event"];
                    match event["type"].as_str() {
                        Some("browser_request") => {
                            assert_eq!(payload["taskId"], task_id);
                            assert_eq!(event["tabId"], Uuid::nil().to_string());
                            let request_id = event["requestId"].as_str().unwrap().to_owned();
                            let result = if event["action"] == "screenshot" {
                                let staging = data_root.join("CodexBrowserStaging");
                                std::fs::create_dir_all(&staging)?;
                                let png = include_bytes!("../tests/fixtures/one-pixel.png");
                                std::fs::write(staging.join(format!("{request_id}.png")), png)?;
                                saw_screenshot = true;
                                json!({"status":"ok","tab_id":Uuid::nil().to_string(),
                                    "byte_count":png.len()})
                            } else if event["action"] == "download" {
                                assert_eq!(event["handle"], "scan:2");
                                saw_download = true;
                                json!({"status":"ok","download_id":Uuid::nil().to_string()})
                            } else if event["action"] == "site_tool_call" {
                                assert_eq!(event["siteTool"], "read_title");
                                assert_eq!(event["arguments"], json!({"section":"intro"}));
                                saw_site_tool = true;
                                json!({"status":"ok","site_tool":"read_title",
                                    "output":"{\"title\":\"Site tools\"}"})
                            } else {
                                assert_eq!(event["action"], "fill");
                                assert_eq!(event["handle"], "scan:1");
                                assert_eq!(event["text"], "sample");
                                saw_request = true;
                                json!({"status":"ok","action":"filled"})
                            };
                            bridge.resolve_browser(CodexBrowserResolution {
                                task_id: task_id.clone(), request_id, result,
                            })?;
                        }
                        Some("agent_message") => {
                            saw_reply |= event["message"] == "Found the page";
                        }
                        Some("task_complete") => break,
                        Some("error") => anyhow::bail!("Codex browser tool error: {event}"),
                        _ => {}
                    }
                }
                assert!(saw_request && saw_screenshot && saw_download && saw_site_tool && saw_reply);
                let requests = server.received_requests().await.unwrap();
                assert!(String::from_utf8_lossy(&requests[0].body).contains("shipios_browser"));
                assert!(String::from_utf8_lossy(&requests[1].body).contains("filled"));
                assert!(String::from_utf8_lossy(&requests[2].body).contains("input_image"));
                assert!(String::from_utf8_lossy(&requests[2].body).contains("data:image/png;base64,"));
                assert!(String::from_utf8_lossy(&requests[3].body).contains("download_id"));
                assert!(String::from_utf8_lossy(&requests[4].body).contains("Site tools"));
                assert_eq!(std::fs::read_dir(data_root.join("CodexBrowserStaging"))?.count(), 0);
                Ok::<_, anyhow::Error>(())
            })
            .await
            .context("Codex browser worker failed")?
        })
    }

    #[test]
    fn model_confetti_call_reaches_the_task_window() -> Result<()> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_stack_size(16 * 1024 * 1024)
            .build()?;
        runtime.block_on(async {
            tokio::spawn(async move {
                let server = MockServer::start().await;
                let sse = |events: Vec<Value>| {
                    events
                        .into_iter()
                        .map(|event| {
                            format!(
                                "event: {}\ndata: {event}\n\n",
                                event["type"].as_str().unwrap()
                            )
                        })
                        .collect::<String>()
                };
                let completed = |id: &str| {
                    json!({"type":"response.completed","response":{
                        "id":id,"usage":{"input_tokens":0,"input_tokens_details":null,
                        "output_tokens":0,"output_tokens_details":null,"total_tokens":0}}})
                };
                let call = sse(vec![
                    json!({"type":"response.created","response":{"id":"confetti-1"}}),
                    json!({"type":"response.output_item.done","item":{
                        "type":"function_call","call_id":"fire-1",
                        "name":"shipios_fire_confetti","arguments":"{}"}}),
                    completed("confetti-1"),
                ]);
                let done = sse(vec![
                    json!({"type":"response.created","response":{"id":"confetti-2"}}),
                    json!({"type":"response.output_item.done","item":{
                        "type":"message","role":"assistant","id":"celebrated",
                        "content":[{"type":"output_text","text":"Celebrated"}]}}),
                    completed("confetti-2"),
                ]);
                let count = std::sync::atomic::AtomicUsize::new(0);
                Mock::given(method("POST"))
                    .and(path("/v1/responses"))
                    .respond_with(move |_request: &wiremock::Request| {
                        let body = if count.fetch_add(1, std::sync::atomic::Ordering::SeqCst) == 0 {
                            &call
                        } else {
                            &done
                        };
                        ResponseTemplate::new(200)
                            .insert_header("content-type", "text/event-stream")
                            .set_body_string(body.clone())
                    })
                    .expect(2)
                    .mount(&server)
                    .await;
                let temp = tempfile::tempdir()?;
                let project = temp.path().join("Project");
                let data = temp.path().join("Data/Projects/fixture");
                std::fs::create_dir_all(&project)?;
                std::fs::create_dir_all(&data)?;
                let bridge = CodexBridge::new(data, project);
                let mut events = bridge.subscribe();
                let task_id = Uuid::new_v4().to_string();
                bridge
                    .start(StartThread {
                        task_id: task_id.clone(),
                        base_url: format!("{}/v1", server.uri()),
                        model: "gpt-5.4".to_owned(),
                        api_key: None,
                        initial_context_bytes: Some(0),
                        resume_only: false,
                        read_only: false,
                        text_only: false,
                        additional_folders: Vec::new(),
                        permissions: SessionPermissions::default(),
                        permissions_selection_explicit: false,
                        permission_profile_id: None,
                        permission_profile_config: None,
                        permission_profile_selection_explicit: false,
                        responses: SessionResponsePreferences::default(),
                        web_search: SessionWebSearch::default(),
                        mcp_servers: Vec::new(),
                        confetti_enabled: true,
                        fork_origin: None,
                        resume_origin: None,
                    })
                    .await?;
                bridge
                    .submit(&task_id, "Please celebrate with confetti".to_owned())
                    .await?;
                let mut fired = false;
                let mut replied = false;
                loop {
                    let payload =
                        tokio::time::timeout(std::time::Duration::from_secs(15), events.recv())
                            .await??;
                    assert_eq!(payload["taskId"], task_id);
                    match payload["event"]["type"].as_str() {
                        Some("confetti_fire") => fired = true,
                        Some("agent_message") => {
                            replied |= payload["event"]["message"] == "Celebrated"
                        }
                        Some("task_complete") => break,
                        Some("error") => {
                            anyhow::bail!("Codex confetti error: {}", payload["event"])
                        }
                        _ => {}
                    }
                }
                assert!(fired && replied);
                let requests = server.received_requests().await.unwrap();
                assert!(
                    String::from_utf8_lossy(&requests[0].body).contains("shipios_fire_confetti")
                );
                assert!(String::from_utf8_lossy(&requests[1].body).contains("requested"));
                Ok::<_, anyhow::Error>(())
            })
            .await
            .context("Codex confetti worker failed")?
        })
    }

    #[test]
    fn task_thread_streams_reply_and_clears_ephemeral_auth() -> Result<()> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_stack_size(16 * 1024 * 1024)
            .build()?;
        runtime.block_on(async {
            tokio::spawn(async move { test_task_thread().await })
                .await
                .context("Codex test worker failed")?
        })
    }

    async fn test_task_thread() -> Result<()> {
        let server = MockServer::start().await;
        let response = [
            json!({"type":"response.created","response":{"id":"resp-1"}}),
            json!({"type":"response.output_item.done","item":{
                "type":"message","role":"assistant","id":"msg-1",
                "content":[{"type":"output_text","text":"Agent bridge reply"}]
            }}),
            json!({"type":"response.completed","response":{
                "id":"resp-1","usage":{"input_tokens":0,"input_tokens_details":null,
                "output_tokens":0,"output_tokens_details":null,"total_tokens":0}
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
            .expect(5)
            .mount(&server)
            .await;
        let temp = tempfile::tempdir()?;
        let project = temp.path().join("Project");
        std::fs::create_dir_all(&project)?;
        let data_dir = temp.path().join("Data/Projects/fixture");
        std::fs::create_dir_all(&data_dir)?;
        let bridge = CodexBridge::new(data_dir.clone(), project);
        let mut events = bridge.subscribe();
        let task_id = Uuid::new_v4().to_string().to_uppercase();
        let custom_permissions = SessionPermissions {
            approval_policy: SessionApprovalPolicy::Never,
            approval_reviewer: SessionApprovalReviewer::User,
            sandbox_mode: SessionSandboxMode::WorkspaceWrite,
            network_access: true,
        };
        let custom_responses = SessionResponsePreferences {
            verbosity: Some(Verbosity::High),
            reasoning_summary: Some(ReasoningSummary::Concise),
        };
        let custom_web_search = SessionWebSearch {
            mode: WebSearchMode::Cached,
            supports_hosted_web_search: true,
        };
        assert!(
            bridge
                .start(StartThread {
                    task_id: task_id.clone(),
                    base_url: format!("{}/v1", server.uri()),
                    model: "gpt-5.4".to_owned(),
                    api_key: None,
                    initial_context_bytes: Some(0),
                    resume_only: true,
                    fork_origin: None,
                    resume_origin: None,
                    read_only: false,
                    text_only: false,
                    additional_folders: Vec::new(),
                    permissions: SessionPermissions::default(),
                    permissions_selection_explicit: false,
                    permission_profile_id: None,
                    permission_profile_config: None,
                    permission_profile_selection_explicit: false,
                    responses: SessionResponsePreferences::default(),
                    web_search: SessionWebSearch::default(),
                    mcp_servers: Vec::new(),
                    confetti_enabled: false,
                })
                .await
                .is_err()
        );
        assert!(
            !data_dir
                .join("Codex/Tasks")
                .join(task_id.to_lowercase())
                .join("thread.json")
                .exists()
        );
        assert!(
            bridge
                .start(StartThread {
                    task_id: task_id.clone(),
                    base_url: format!("{}/v1", server.uri()),
                    model: "gpt-5.4".to_owned(),
                    api_key: None,
                    initial_context_bytes: Some(48_001),
                    resume_only: false,
                    fork_origin: None,
                    resume_origin: None,
                    read_only: false,
                    text_only: false,
                    additional_folders: Vec::new(),
                    permissions: SessionPermissions::default(),
                    permissions_selection_explicit: false,
                    permission_profile_id: None,
                    permission_profile_config: None,
                    permission_profile_selection_explicit: false,
                    responses: SessionResponsePreferences::default(),
                    web_search: SessionWebSearch::default(),
                    mcp_servers: Vec::new(),
                    confetti_enabled: false,
                })
                .await
                .is_err()
        );
        let thread = bridge
            .start(StartThread {
                task_id: task_id.clone(),
                base_url: format!("{}/v1", server.uri()),
                model: "gpt-5.4".to_owned(),
                api_key: Some("bridge-test-token".to_owned()),
                initial_context_bytes: Some(48_000),
                resume_only: false,
                fork_origin: None,
                resume_origin: None,
                read_only: false,
                text_only: false,
                additional_folders: Vec::new(),
                permissions: custom_permissions,
                permissions_selection_explicit: false,
                permission_profile_id: None,
                permission_profile_config: None,
                permission_profile_selection_explicit: false,
                responses: custom_responses,
                web_search: custom_web_search,
                mcp_servers: Vec::new(),
                confetti_enabled: false,
            })
            .await?;
        assert_eq!(thread.task_id, task_id);
        assert!(!thread.resumed);
        let task_home = data_dir.join("Codex/Tasks").join(task_id.to_lowercase());
        assert!(!bridge.submit(&task_id, " ".to_owned()).await.is_ok());
        assert!(
            !bridge
                .submit(&Uuid::new_v4().to_string(), "hi".to_owned())
                .await
                .is_ok()
        );
        let turn_id = bridge.submit(&task_id, "Hi".to_owned()).await?;
        assert!(!turn_id.is_empty());
        let mut reply = None;
        loop {
            let event =
                tokio::time::timeout(std::time::Duration::from_secs(10), events.recv()).await??;
            assert_eq!(event["taskId"], task_id);
            assert_eq!(event["threadId"], thread.thread_id);
            match event["event"]["type"].as_str() {
                Some("agent_message") => {
                    reply = event["event"]["message"].as_str().map(str::to_owned)
                }
                Some("task_complete") => break,
                Some("error") => anyhow::bail!("Codex error: {}", event["event"]),
                _ => {}
            }
        }
        assert_eq!(reply.as_deref(), Some("Agent bridge reply"));
        assert_eq!(
            saved_thread(&task_home)?.unwrap().permissions,
            custom_permissions
        );
        assert_eq!(
            saved_thread(&task_home)?.unwrap().responses,
            custom_responses
        );
        assert_eq!(
            saved_thread(&task_home)?.unwrap().web_search,
            custom_web_search
        );
        let child_id = Uuid::new_v4().to_string();
        let origin = || ForkThreadOrigin {
            task_id: task_id.clone(),
            workspace: bridge.project.clone(),
            thread_id: thread.thread_id.clone(),
            through_turn_id: turn_id.clone(),
        };
        let fork_request = |fork_origin| StartThread {
            task_id: child_id.clone(),
            base_url: format!("{}/v1", server.uri()),
            model: "gpt-5.4".to_owned(),
            api_key: Some("bridge-test-token".to_owned()),
            initial_context_bytes: Some(80_000),
            resume_only: false,
            fork_origin: Some(fork_origin),
            resume_origin: None,
            read_only: false,
            text_only: false,
            additional_folders: Vec::new(),
            permissions: SessionPermissions::default(),
            permissions_selection_explicit: false,
            permission_profile_id: None,
            permission_profile_config: None,
            permission_profile_selection_explicit: false,
            responses: SessionResponsePreferences::default(),
            web_search: SessionWebSearch::default(),
            mcp_servers: Vec::new(),
            confetti_enabled: false,
        };
        let mut missing_turn = origin();
        missing_turn.through_turn_id = "missing-turn".to_owned();
        assert!(bridge.start(fork_request(missing_turn)).await.is_err());
        let mut wrong_thread = origin();
        wrong_thread.thread_id = Uuid::new_v4().to_string();
        assert!(bridge.start(fork_request(wrong_thread)).await.is_err());
        let child = bridge.start(fork_request(origin())).await?;
        assert!(child.forked && !child.resumed);
        assert_ne!(child.thread_id, thread.thread_id);
        let child_home = data_dir.join("Codex/Tasks").join(&child_id);
        let saved_child = saved_thread(&child_home)?.unwrap();
        assert_eq!(saved_child.permissions, custom_permissions);
        assert_eq!(saved_child.responses, custom_responses);
        assert_eq!(saved_child.web_search, custom_web_search);
        let child_history = std::fs::read_to_string(saved_child.rollout_path)?;
        assert!(child_history.contains(&thread.thread_id));
        assert!(child_history.contains("Agent bridge reply"));
        bridge.submit(&child_id, "Fork followup".to_owned()).await?;
        loop {
            let event =
                tokio::time::timeout(std::time::Duration::from_secs(10), events.recv()).await??;
            if event["taskId"] != child_id {
                continue;
            }
            match event["event"]["type"].as_str() {
                Some("task_complete") => break,
                Some("error") => anyhow::bail!("Codex fork error: {}", event["event"]),
                _ => {}
            }
        }
        bridge.stop(&child_id).await?;
        bridge.stop(&task_id).await?;
        assert!(bridge.submit(&task_id, "Again".to_owned()).await.is_err());
        let restarted = CodexBridge::new(data_dir.clone(), temp.path().join("Project"));
        let mut resumed_events = restarted.subscribe();
        let resumed = restarted
            .start(StartThread {
                task_id: task_id.clone(),
                base_url: format!("{}/v1", server.uri()),
                model: "gpt-5.4".to_owned(),
                api_key: Some("bridge-test-token".to_owned()),
                initial_context_bytes: Some(48_001),
                resume_only: false,
                fork_origin: None,
                resume_origin: None,
                read_only: false,
                text_only: false,
                additional_folders: Vec::new(),
                permissions: SessionPermissions::default(),
                permissions_selection_explicit: false,
                permission_profile_id: None,
                permission_profile_config: None,
                permission_profile_selection_explicit: false,
                responses: SessionResponsePreferences::default(),
                web_search: SessionWebSearch::default(),
                mcp_servers: Vec::new(),
                confetti_enabled: false,
            })
            .await?;
        assert_eq!(
            saved_thread(&task_home)?.unwrap().permissions,
            custom_permissions
        );
        assert_eq!(
            saved_thread(&task_home)?.unwrap().responses,
            custom_responses
        );
        assert_eq!(
            saved_thread(&task_home)?.unwrap().web_search,
            custom_web_search
        );
        assert!(resumed.resumed);
        assert_eq!(resumed.thread_id, thread.thread_id);
        restarted.submit(&task_id, "Again".to_owned()).await?;
        let mut resumed_reply = None;
        loop {
            let event =
                tokio::time::timeout(std::time::Duration::from_secs(10), resumed_events.recv())
                    .await??;
            match event["event"]["type"].as_str() {
                Some("agent_message") => {
                    resumed_reply = event["event"]["message"].as_str().map(str::to_owned)
                }
                Some("task_complete") => break,
                Some("error") => anyhow::bail!("Codex resume error: {}", event["event"]),
                _ => {}
            }
        }
        assert_eq!(resumed_reply.as_deref(), Some("Agent bridge reply"));
        let image_id = Uuid::new_v4().to_string().to_uppercase();
        let image_bytes: &[u8] = &[
            137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 2, 0, 0, 0, 2,
            8, 2, 0, 0, 0, 253, 212, 154, 115, 0, 0, 0, 18, 73, 68, 65, 84, 120, 156, 99, 84, 104,
            120, 192, 192, 192, 192, 196, 0, 6, 0, 17, 106, 1, 132, 39, 161, 5, 66, 0, 0, 0, 0, 73,
            69, 78, 68, 174, 66, 96, 130,
        ];
        let attachments = temp.path().join("Data/Attachments");
        std::fs::create_dir_all(&attachments)?;
        std::fs::write(attachments.join(format!("{image_id}.png")), image_bytes)?;
        let image = CodexImage {
            id: image_id,
            file_extension: "png".to_owned(),
            byte_count: image_bytes.len() as u64,
        };
        assert!(
            restarted
                .submit_with_images(
                    &task_id,
                    String::new(),
                    vec![CodexImage {
                        id: Uuid::new_v4().to_string(),
                        file_extension: "png".to_owned(),
                        byte_count: image_bytes.len() as u64,
                    }],
                )
                .await
                .is_err()
        );
        restarted
            .submit_with_images(&task_id, String::new(), vec![image])
            .await?;
        loop {
            let event =
                tokio::time::timeout(std::time::Duration::from_secs(10), resumed_events.recv())
                    .await??;
            match event["event"]["type"].as_str() {
                Some("task_complete") => break,
                Some("error") => anyhow::bail!("Codex image error: {}", event["event"]),
                _ => {}
            }
        }
        let staging = temp.path().join("Data/CodexStaging");
        std::fs::create_dir_all(&staging)?;
        let text_id = Uuid::new_v4().to_string().to_uppercase();
        let text_path = staging.join(format!("{text_id}.txt"));
        let text_appendix = format!(
            "\nFILE_MARKER_START\n{}\nFILE_MARKER_END",
            "x".repeat(80_000)
        );
        std::fs::write(&text_path, &text_appendix)?;
        restarted
            .submit_with_attachments(CodexSubmit {
                task_id: task_id.clone(),
                text: "Read the attached file".to_owned(),
                images: Vec::new(),
                text_attachment: Some(CodexTextAttachment {
                    id: text_id,
                    byte_count: text_appendix.len() as u64,
                }),
                plan_mode: false,
                goal_instructions: None,
                model: None,
                reasoning_effort: None,
                permissions: None,
            })
            .await?;
        loop {
            let event =
                tokio::time::timeout(std::time::Duration::from_secs(10), resumed_events.recv())
                    .await??;
            match event["event"]["type"].as_str() {
                Some("task_complete") => break,
                Some("error") => anyhow::bail!("Codex file error: {}", event["event"]),
                _ => {}
            }
        }
        assert!(!text_path.exists(), "the Agent did not remove staged text");
        restarted.stop(&task_id).await?;
        let home = data_dir.join("Codex/Tasks").join(task_id.to_lowercase());
        assert!(!home.join("auth.json").exists());
        let requests = server.received_requests().await.expect("mock requests");
        assert_eq!(requests.len(), 5);
        for request in requests.iter().take(3) {
            let body: serde_json::Value = serde_json::from_slice(&request.body)?;
            assert_eq!(body["text"]["verbosity"], "high");
            assert_eq!(body["reasoning"]["summary"], "concise");
            assert!(
                body["tools"]
                    .as_array()
                    .is_some_and(|tools| tools.iter().any(|tool| {
                        tool["type"] == "web_search" && tool["external_web_access"] == false
                    }))
            );
        }
        let fork_request: Value = serde_json::from_slice(&requests[1].body)?;
        assert!(fork_request["input"].to_string().contains("Fork followup"));
        assert!(
            fork_request["input"]
                .to_string()
                .contains("Agent bridge reply")
        );
        let image_request: serde_json::Value = serde_json::from_slice(&requests[3].body)?;
        assert!(
            image_request["input"]
                .as_array()
                .and_then(|items| items.last())
                .is_some_and(|last| last.to_string().contains("data:image/png;base64,")),
            "the fourth model request did not contain the local image"
        );
        let file_request: serde_json::Value = serde_json::from_slice(&requests[4].body)?;
        assert!(
            file_request["input"]
                .as_array()
                .and_then(|items| items.last())
                .is_some_and(|last| last.to_string().contains("FILE_MARKER_END")),
            "the fifth model request did not contain the staged file text"
        );
        assert_eq!(
            requests[0]
                .headers
                .get("authorization")
                .and_then(|value| value.to_str().ok()),
            Some("Bearer bridge-test-token")
        );
        server.verify().await;
        Ok(())
    }
}
