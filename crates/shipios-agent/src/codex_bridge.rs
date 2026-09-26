use anyhow::{Context, Result, anyhow, ensure};
use codex_core_api::UserInput;
use codex_protocol::mcp::RequestId;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use shipios_codex::{
    ApprovalDecision, CodexSession, CodexTurnMode, ElicitationDecision, SessionOptions,
    ShipMcpServer,
};
use shipios_core::config::private_dir;
use std::{collections::HashMap, path::PathBuf, sync::Arc};
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
    pub read_only: bool,
    #[serde(default)]
    pub mcp_servers: Vec<ShipMcpServer>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadInfo {
    pub task_id: String,
    pub thread_id: String,
    pub resumed: bool,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PersistedThread {
    thread_id: String,
    rollout_path: PathBuf,
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

fn saved_thread(home: &std::path::Path) -> Result<Option<PersistedThread>> {
    let path = home.join("thread.json");
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

enum Command {
    Submit {
        inputs: Vec<UserInput>,
        mode: CodexTurnMode,
        model: Option<String>,
        reasoning_effort: Option<String>,
        reply: oneshot::Sender<Result<String>>,
    },
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
}

impl CodexBridge {
    pub fn new(data_dir: PathBuf, project: PathBuf) -> Self {
        let (events, _) = broadcast::channel(256);
        Self {
            data_dir,
            project,
            sessions: Arc::new(Mutex::new(HashMap::new())),
            events,
        }
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Value> {
        self.events.subscribe()
    }

    pub async fn start(&self, request: StartThread) -> Result<ThreadInfo> {
        let task_id = request.task_id;
        let task_key = Uuid::parse_str(&task_id)
            .context("taskId must be a UUID")?
            .hyphenated()
            .to_string();
        ensure!(
            !self.sessions.lock().await.contains_key(&task_key),
            "Codex thread already exists for task"
        );
        let home = private_dir(&self.data_dir.join("Codex"))?;
        let home = private_dir(&home.join("Tasks"))?;
        let home = private_dir(&home.join(&task_key))?
            .canonicalize()
            .context("resolve private Codex home")?;
        let previous = saved_thread(&home)?;
        if previous.is_none() {
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
        let options = SessionOptions {
            codex_home: home.clone(),
            project_root: self.project.clone(),
            base_url: request.base_url,
            model: request.model,
            api_key: request.api_key,
            read_only: request.read_only,
            mcp_servers: request.mcp_servers,
            runtime_paths,
        };
        let resumed = previous.is_some();
        let session = if let Some(ref previous) = previous {
            CodexSession::resume(options, previous.rollout_path.clone()).await?
        } else {
            CodexSession::start(options).await?
        };
        let thread_id = session.thread_id();
        if let Some(ref previous) = previous {
            if previous.thread_id != thread_id {
                let _ = session.shutdown().await;
                return Err(anyhow!("resumed Codex thread identity changed"));
            }
        }
        let saved = session.rollout_path().map(|rollout_path| PersistedThread {
            thread_id: thread_id.clone(),
            rollout_path,
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
        self.submit_with_attachments(task_id, text, Vec::new(), None, false, None, None, None)
            .await
    }

    #[cfg(test)]
    pub async fn submit_with_images(
        &self,
        task_id: &str,
        text: String,
        images: Vec<CodexImage>,
    ) -> Result<String> {
        self.submit_with_attachments(task_id, text, images, None, false, None, None, None)
            .await
    }

    pub async fn submit_with_attachments(
        &self,
        task_id: &str,
        text: String,
        images: Vec<CodexImage>,
        text_attachment: Option<CodexTextAttachment>,
        plan_mode: bool,
        goal_instructions: Option<String>,
        model: Option<String>,
        reasoning_effort: Option<String>,
    ) -> Result<String> {
        ensure!(
            !plan_mode || goal_instructions.is_none(),
            "plan and goal modes cannot be combined"
        );
        let inputs = self.inputs_with_attachments(text, images, text_attachment)?;
        let (reply, result) = oneshot::channel();
        self.sender(task_id)
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
                reply,
            })
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
        let (reply, result) = oneshot::channel();
        self.sender(task_id)
            .await?
            .send(Command::Interrupt(reply))
            .await
            .context("Codex thread stopped")?;
        result.await.context("Codex thread stopped")?
    }

    pub async fn stop(&self, task_id: &str) -> Result<()> {
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
                Some(Command::Submit { inputs, mode, model, reasoning_effort, reply }) => {
                    let _ = reply.send(live.submit_inputs_in_mode(inputs, mode, model, reasoning_effort).await);
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
    use serde_json::json;
    use wiremock::matchers::{method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

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
            .expect(4)
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
        assert!(
            bridge
                .start(StartThread {
                    task_id: task_id.clone(),
                    base_url: format!("{}/v1", server.uri()),
                    model: "gpt-5.2".to_owned(),
                    api_key: None,
                    initial_context_bytes: Some(48_001),
                    read_only: false,
                    mcp_servers: Vec::new(),
                })
                .await
                .is_err()
        );
        let thread = bridge
            .start(StartThread {
                task_id: task_id.clone(),
                base_url: format!("{}/v1", server.uri()),
                model: "gpt-5.2".to_owned(),
                api_key: Some("bridge-test-token".to_owned()),
                initial_context_bytes: Some(48_000),
                read_only: false,
                mcp_servers: Vec::new(),
            })
            .await?;
        assert_eq!(thread.task_id, task_id);
        assert!(!thread.resumed);
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
        bridge.stop(&task_id).await?;
        assert!(bridge.submit(&task_id, "Again".to_owned()).await.is_err());
        let restarted = CodexBridge::new(data_dir.clone(), temp.path().join("Project"));
        let mut resumed_events = restarted.subscribe();
        let resumed = restarted
            .start(StartThread {
                task_id: task_id.clone(),
                base_url: format!("{}/v1", server.uri()),
                model: "gpt-5.2".to_owned(),
                api_key: Some("bridge-test-token".to_owned()),
                initial_context_bytes: Some(48_001),
                read_only: false,
                mcp_servers: Vec::new(),
            })
            .await?;
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
            .submit_with_attachments(
                &task_id,
                "Read the attached file".to_owned(),
                Vec::new(),
                Some(CodexTextAttachment {
                    id: text_id,
                    byte_count: text_appendix.len() as u64,
                }),
                false,
                None,
                None,
                None,
            )
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
        assert_eq!(requests.len(), 4);
        let image_request: serde_json::Value = serde_json::from_slice(&requests[2].body)?;
        assert!(
            image_request["input"]
                .as_array()
                .and_then(|items| items.last())
                .is_some_and(|last| last.to_string().contains("data:image/png;base64,")),
            "the third model request did not contain the local image"
        );
        let file_request: serde_json::Value = serde_json::from_slice(&requests[3].body)?;
        assert!(
            file_request["input"]
                .as_array()
                .and_then(|items| items.last())
                .is_some_and(|last| last.to_string().contains("FILE_MARKER_END")),
            "the fourth model request did not contain the staged file text"
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
