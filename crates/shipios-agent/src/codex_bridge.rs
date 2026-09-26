use anyhow::{Context, Result, anyhow, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use shipios_codex::{CodexSession, SessionOptions};
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
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadInfo {
    pub task_id: String,
    pub thread_id: String,
}

enum Command {
    Submit(String, oneshot::Sender<Result<String>>),
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
        let home = private_dir(&home.join(&task_key))?;
        let runtime_paths = codex_core_api::ExecServerRuntimePaths::new(
            std::env::current_exe().context("resolve Agent executable")?,
            None,
        )?;
        let session = CodexSession::start(SessionOptions {
            codex_home: home,
            project_root: self.project.clone(),
            base_url: request.base_url,
            model: request.model,
            api_key: request.api_key,
            runtime_paths,
        })
        .await?;
        let thread_id = session.thread_id();
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
        Ok(ThreadInfo { task_id, thread_id })
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

    pub async fn submit(&self, task_id: &str, text: String) -> Result<String> {
        let (reply, result) = oneshot::channel();
        self.sender(task_id)
            .await?
            .send(Command::Submit(text, reply))
            .await
            .context("Codex thread stopped")?;
        result.await.context("Codex thread stopped")?
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
                Some(Command::Submit(text, reply)) => {
                    let _ = reply.send(live.submit_text(text).await);
                }
                Some(Command::Interrupt(reply)) => {
                    let _ = reply.send(live.interrupt_turn().await);
                }
                Some(Command::Stop(reply)) => {
                    let result = live.interrupt_turn().await;
                    let shutdown = session.take().expect("live session").shutdown().await;
                    let _ = reply.send(result.and(shutdown));
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
            .expect(1)
            .mount(&server)
            .await;
        let temp = tempfile::tempdir()?;
        let project = temp.path().join("Project");
        std::fs::create_dir_all(&project)?;
        let bridge = CodexBridge::new(temp.path().join("Data"), project);
        let mut events = bridge.subscribe();
        let task_id = Uuid::new_v4().to_string().to_uppercase();
        let thread = bridge
            .start(StartThread {
                task_id: task_id.clone(),
                base_url: format!("{}/v1", server.uri()),
                model: "gpt-5.2".to_owned(),
                api_key: Some("bridge-test-token".to_owned()),
            })
            .await?;
        assert_eq!(thread.task_id, task_id);
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
        let home = temp
            .path()
            .join("Data/Codex/Tasks")
            .join(task_id.to_lowercase());
        assert!(!home.join("auth.json").exists());
        let requests = server.received_requests().await.expect("mock requests");
        assert_eq!(requests.len(), 1);
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
