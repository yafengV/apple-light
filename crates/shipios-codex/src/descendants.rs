use anyhow::{Result, bail, ensure};
use codex_core_api::{
    SessionSource, StartIfIdleSubmission, SteerSubmission, ThreadId, ThreadManager,
    TurnInputRequest, UserInput,
};
use codex_protocol::protocol::{AgentStatus, SubAgentSource};
use serde::Serialize;
use std::{
    collections::{HashMap, HashSet},
    sync::Arc,
};
use tokio::sync::{Mutex, RwLock, broadcast};

/// Runtime-local proof from Core, rather than an inference from inherited history
/// or a tool's requested target. Fresh forks never receive this callback.
pub(crate) struct NativeResumeObserver;
struct ResumedRuntime;

impl codex_extension_api::ThreadLifecycleContributor<codex_core_api::Config>
    for NativeResumeObserver
{
    fn on_thread_resume<'a>(
        &'a self,
        input: codex_extension_api::ThreadResumeInput<'a>,
    ) -> codex_extension_api::ExtensionFuture<'a, ()> {
        Box::pin(async move {
            input.thread_store.insert(ResumedRuntime);
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeSubagent {
    pub thread_id: String,
    pub parent_thread_id: Option<String>,
    pub nickname: Option<String>,
    pub role: Option<String>,
    pub depth: Option<i32>,
    pub model: Option<String>,
    pub reasoning_effort: Option<String>,
    pub status: String,
    pub loaded: bool,
    /// Summary only. The full child transcript must be read separately.
    pub preview: Option<String>,
    /// Latest public delegation from this child's actual owner, not inherited
    /// user history or the child's final reply. Bounded overview metadata only.
    pub objective: Option<String>,
    /// Product recency, never the time this snapshot happened to be polled.
    pub recency_at_ms: Option<i64>,
    pub started_at_ms: Option<i64>,
    pub last_assistant_message_at_ms: Option<i64>,
}

/// A task-private manager view. The host owns one event reader per loaded child;
/// durable history and status discovery do not consume events.
#[derive(Clone)]
pub struct DescendantSource {
    manager: Arc<ThreadManager>,
    parent: ThreadId,
    reload: Arc<Mutex<()>>,
    reloaded: Arc<RwLock<HashSet<ThreadId>>>,
    store: Arc<dyn codex_thread_store::ThreadStore>,
    graph: Option<Arc<dyn codex_agent_graph_store::AgentGraphStore>>,
}

impl DescendantSource {
    pub(crate) fn new(
        manager: Arc<ThreadManager>,
        parent: ThreadId,
        store: Arc<dyn codex_thread_store::ThreadStore>,
        graph: Option<Arc<dyn codex_agent_graph_store::AgentGraphStore>>,
    ) -> Self {
        Self {
            manager,
            parent,
            reload: Arc::new(Mutex::new(())),
            reloaded: Arc::new(RwLock::new(HashSet::new())),
            store,
            graph,
        }
    }

    pub async fn validate_member(&self, child: &str) -> Result<ThreadId> {
        let id = ThreadId::from_string(child)?;
        ensure!(
            id != self.parent
                && self
                    .snapshot()
                    .await?
                    .iter()
                    .any(|row| row.thread_id == id.to_string()),
            "thread is not a descendant of this task"
        );
        Ok(id)
    }

    /// Load only a validated descendant and its recorded ancestry, root first.
    /// Clones share a gate so concurrent detail windows cannot duplicate reloads.
    pub async fn ensure_loaded(&self, child: &str) -> Result<NativeSubagent> {
        let _reload = self.reload.lock().await;
        let id = self.validate_member(child).await?;
        let previously_loaded: HashSet<_> =
            self.manager.list_thread_ids().await.into_iter().collect();
        let mut chain = Vec::new();
        let mut seen = HashSet::new();
        let mut next = id;
        while next != self.parent {
            ensure!(seen.insert(next), "cyclic child ownership");
            let stored = self
                .store
                .read_thread(codex_thread_store::ReadThreadParams {
                    thread_id: next,
                    include_archived: true,
                    include_history: false,
                })
                .await?;
            let owner = stored
                .parent_thread_id
                .or_else(|| stored.source.parent_thread_id())
                .ok_or_else(|| anyhow::anyhow!("child owner is missing"))?;
            ensure!(
                stored.source.parent_thread_id() == Some(owner),
                "child owner is inconsistent"
            );
            chain.push(next);
            next = owner;
        }
        // Register the cold identities before Core publishes thread-created.
        // A monitor must never see a resumed idle queue as a fresh startup.
        let mut cold = HashSet::new();
        for member in &chain {
            if !previously_loaded.contains(member) {
                cold.insert(*member);
                // Legacy native resume also reopens this owner's open descendants.
                cold.extend(self.manager.list_agent_subtree_thread_ids(*member).await?);
            }
        }
        cold.retain(|member| !previously_loaded.contains(member));
        self.reloaded.write().await.extend(cold);
        for member in chain.into_iter().rev() {
            ensure!(
                !self.closed_descendants().await?.contains(&member),
                "child has been closed"
            );
            self.manager.ensure_child_loaded(member).await?;
        }
        self.snapshot()
            .await?
            .into_iter()
            .find(|row| row.thread_id == child)
            .ok_or_else(|| anyhow::anyhow!("loaded child is no longer available"))
    }

    /// Only the root-owned descendant monitor may claim this receiver. Native
    /// completion watchers subscribe to status, not this host event queue.
    pub async fn event_thread(&self, child: &str) -> Result<Arc<codex_core_api::CodexThread>> {
        let id = self.validate_member(child).await?;
        Ok(self.manager.get_thread(id).await?)
    }

    /// Bind the child's original native waiter. No Op carrying a reused call ID
    /// is submitted, and a failed claim leaves the current request untouched.
    pub async fn claim_approval(
        &self,
        child: &str,
        turn: &str,
        approval_id: &str,
        started_at_ms: i64,
    ) -> Result<codex_core::CapturedApproval> {
        ensure!(
            !turn.is_empty() && !approval_id.is_empty(),
            "invalid approval identity"
        );
        self.event_thread(child)
            .await?
            .claim_approval_for_turn(turn, approval_id, started_at_ms)
            .await
            .ok_or_else(|| anyhow::anyhow!("child approval is no longer available"))
    }

    /// Bind an MCP form/URL request to its native turn and request generation.
    pub async fn claim_elicitation(
        &self,
        child: &str,
        observed_turn: &str,
        request: &codex_protocol::approvals::ElicitationRequestEvent,
    ) -> Result<codex_core::CapturedElicitation> {
        ensure!(
            !observed_turn.is_empty()
                && request
                    .turn_id
                    .as_deref()
                    .is_none_or(|turn| turn == observed_turn),
            "child elicitation turn changed"
        );
        ensure!(
            !request.server_name.is_empty(),
            "missing elicitation server"
        );
        let data = serde_json::to_value(&request.request)?;
        let generation = if request.turn_id.is_some() {
            Some(
                data["_meta"][codex_core::NATIVE_ELICITATION_GENERATION_KEY]
                    .as_u64()
                    .filter(|value| *value > 0)
                    .ok_or_else(|| anyhow::anyhow!("missing native elicitation generation"))?,
            )
        } else {
            None
        };
        let id = serde_json::from_value(serde_json::to_value(&request.id)?)?;
        self.event_thread(child)
            .await?
            .claim_elicitation_for_turn(observed_turn, &request.server_name, &id, generation)
            .await
            .ok_or_else(|| anyhow::anyhow!("child elicitation is no longer available"))
    }

    /// Durable replay history, including pre-compaction messages. This does not
    /// reload a cold child or compete with any child event consumer.
    pub async fn history(&self, child: &str) -> Result<Vec<serde_json::Value>> {
        let id = self.validate_member(child).await?;
        if let Ok(thread) = self.manager.get_thread(id).await {
            thread.flush_rollout().await?;
        }
        let stored = self
            .store
            .load_history(codex_thread_store::LoadThreadHistoryParams {
                thread_id: id,
                include_archived: true,
            })
            .await?;
        ensure!(
            stored.thread_id == id,
            "descendant history identity changed"
        );
        // Host configuration, private developer context and encrypted reasoning
        // are not presentation records. Keep every persisted public event.
        let mut events = Vec::new();
        for item in stored.items {
            match item {
                codex_history::RolloutItem::EventMsg(event) => {
                    if let Some(value) = public_descendant_event(event)? {
                        events.push(value);
                    }
                }
                codex_history::RolloutItem::ResponseItem(entry) => {
                    let mut value = serde_json::to_value(entry.item)?;
                    if !sanitize_response(&mut value) {
                        continue;
                    }
                    events.push(serde_json::json!({"type":"raw_response_item","item":value}));
                }
                codex_history::RolloutItem::Compacted(_) => {
                    events.push(serde_json::json!({"type":"context_compacted"}))
                }
                _ => {}
            }
        }
        Ok(events)
    }

    /// Use the child's own settings and atomic native start/steer routing. No
    /// implicit permission, model or runtime changes accompany a UI message.
    pub async fn submit(
        &self,
        child: &str,
        text: String,
        expected_turn: Option<String>,
    ) -> Result<(String, bool)> {
        ensure!(
            !text.trim().is_empty() && text.len() <= 48_000,
            "invalid child message"
        );
        self.submit_inputs(
            child,
            vec![UserInput::Text {
                text,
                text_elements: Vec::new(),
            }],
            expected_turn,
        )
        .await
    }

    pub async fn submit_inputs(
        &self,
        child: &str,
        inputs: Vec<UserInput>,
        expected_turn: Option<String>,
    ) -> Result<(String, bool)> {
        ensure!(
            inputs.len() <= 9
                && inputs.iter().all(|input| match input {
                    UserInput::Text { text, .. } => text.len() <= 1 << 20,
                    UserInput::LocalImage { .. } => true,
                    _ => false,
                }),
            "invalid child input"
        );
        ensure!(
            inputs.iter().any(|input| match input {
                UserInput::Text { text, .. } => !text.trim().is_empty(),
                UserInput::LocalImage { .. } => true,
                _ => false,
            }),
            "child message is empty"
        );
        let id = self.validate_member(child).await?;
        let thread = self.manager.get_thread(id).await?;
        let input = TurnInputRequest::user_input(inputs);
        if let Some(expected) = expected_turn {
            ensure!(!expected.is_empty(), "expected child turn is empty");
            match thread.steer_turn(input, expected.clone()).await? {
                SteerSubmission::Steered { .. } => Ok((expected, true)),
                SteerSubmission::NotSubmitted { .. } => bail!("child turn identity changed"),
            }
        } else {
            match thread.start_turn_if_idle(input).await? {
                StartIfIdleSubmission::Started { turn_id } => Ok((turn_id, false)),
                StartIfIdleSubmission::NotSubmitted { .. } => bail!("child is already running"),
            }
        }
    }

    pub fn subscribe_created(&self) -> broadcast::Receiver<ThreadId> {
        self.manager.subscribe_thread_created()
    }

    /// A detail-view Stop targets one loaded child and its observed native turn.
    /// No idle/cold child is loaded, and no peer/root or later turn is selected.
    pub async fn interrupt(&self, child: &str, expected_turn: &str) -> Result<bool> {
        ensure!(
            !expected_turn.is_empty() && expected_turn.len() <= 256,
            "invalid child turn identity"
        );
        let thread = self.event_thread(child).await?;
        Ok(thread.interrupt_turn_if_active(expected_turn).await)
    }

    /// A start acknowledgement can precede TurnStarted/status publication.
    /// Observe the accepted turn's durable terminal marker before allowing a
    /// completed subtree monitor to sleep again, including same-text replies.
    pub async fn submission_finished(&self, child: &str, turn: &str) -> Result<bool> {
        let id = ThreadId::from_string(child)?;
        let Ok(thread) = self.manager.get_thread(id).await else {
            return Ok(true);
        };
        if matches!(thread.agent_status().await, AgentStatus::Shutdown) {
            return Ok(true);
        }
        thread.flush_rollout().await?;
        let history = self
            .store
            .load_history(codex_thread_store::LoadThreadHistoryParams {
                thread_id: id,
                include_archived: true,
            })
            .await?;
        let status = thread.agent_status().await;
        for item in history.items.iter().rev() {
            match item {
                codex_history::RolloutItem::EventMsg(codex_core_api::EventMsg::TurnComplete(
                    event,
                )) if event.turn_id == turn => {
                    return Ok(match (&status, &event.error) {
                        (AgentStatus::Completed(reply), None) => reply == &event.last_agent_message,
                        (AgentStatus::Errored(message), Some(error)) => message == &error.message,
                        _ => false,
                    });
                }
                codex_history::RolloutItem::EventMsg(codex_core_api::EventMsg::TurnAborted(
                    event,
                )) if event.turn_id.as_deref() == Some(turn) => {
                    return Ok(matches!(
                        status,
                        AgentStatus::Interrupted | AgentStatus::Errored(_)
                    ));
                }
                _ => {}
            }
        }
        Ok(false)
    }

    pub async fn snapshot(&self) -> Result<Vec<NativeSubagent>> {
        let closed = self.closed_descendants().await?;
        let mut members: HashSet<_> = self
            .manager
            .list_agent_subtree_thread_ids(self.parent)
            .await?
            .into_iter()
            .collect();
        members.insert(self.parent);
        let mut loaded = HashMap::new();
        // A just-created thread can precede its durable graph edge. Its actual
        // SessionSource supplies the same parent relationship without loading
        // cold history or confusing unrelated roots with descendants.
        for id in self.manager.list_thread_ids().await {
            if id == self.parent {
                continue;
            }
            let Ok(thread) = self.manager.get_thread(id).await else {
                continue;
            };
            let config = thread.config_snapshot().await;
            let SessionSource::SubAgent(SubAgentSource::ThreadSpawn {
                parent_thread_id,
                depth,
                agent_nickname,
                agent_role,
                ..
            }) = config.session_source
            else {
                continue;
            };
            let reloaded = self.reloaded.read().await.contains(&id)
                || thread
                    .thread_extension_data()
                    .get::<ResumedRuntime>()
                    .is_some();
            let (status, preview) = match thread.agent_status().await {
                AgentStatus::PendingInit if reloaded => {
                    // A resumed idle Core queue starts PendingInit even when its
                    // recorded last turn completed. Present that durable state;
                    // do not synthesize a turn or alter native completion watchers.
                    let history = self
                        .store
                        .load_history(codex_thread_store::LoadThreadHistoryParams {
                            thread_id: id,
                            include_archived: true,
                        })
                        .await
                        .ok();
                    history
                        .as_ref()
                        .and_then(|history| durable_summary(&history.items, "interrupted"))
                        .unwrap_or(("pendingInit", None))
                }
                AgentStatus::PendingInit => ("pendingInit", None),
                AgentStatus::Running => ("running", None),
                AgentStatus::Interrupted => ("interrupted", None),
                AgentStatus::Completed(text) => {
                    ("completed", text.map(|s| s.chars().take(1024).collect()))
                }
                AgentStatus::Errored(_) => ("failed", None),
                AgentStatus::Shutdown => ("shutdown", None),
                AgentStatus::NotFound => ("notLoaded", None),
            };
            thread.flush_rollout().await?;
            let stored = self
                .store
                .read_thread(codex_thread_store::ReadThreadParams {
                    thread_id: id,
                    include_archived: true,
                    include_history: true,
                })
                .await
                .ok();
            let timing = if let Some(stored) = &stored {
                crate::descendant_timing::Timing::from_stored(stored).await
            } else {
                crate::descendant_timing::Timing::default()
            };
            loaded.insert(
                id,
                (
                    parent_thread_id,
                    NativeSubagent {
                        thread_id: id.to_string(),
                        parent_thread_id: Some(parent_thread_id.to_string()),
                        nickname: agent_nickname,
                        role: agent_role,
                        depth: Some(depth),
                        model: Some(config.model),
                        reasoning_effort: config.reasoning_effort.map(|v| v.to_string()),
                        status: status.to_owned(),
                        loaded: status != "notLoaded",
                        preview,
                        objective: None,
                        recency_at_ms: stored
                            .as_ref()
                            .map(|thread| thread.recency_at.timestamp_millis()),
                        started_at_ms: timing.started_at_ms,
                        last_assistant_message_at_ms: timing.last_assistant_message_at_ms,
                    },
                ),
            );
        }
        loop {
            let before = members.len();
            for (id, (parent, _)) in &loaded {
                if members.contains(parent) {
                    members.insert(*id);
                }
            }
            if members.len() == before {
                break;
            }
        }
        members.remove(&self.parent);
        let mut rows = Vec::with_capacity(members.len());
        for id in members {
            let mut row = if let Some((_, row)) = loaded.remove(&id) {
                row
            } else {
                // Discovery must carry its own metadata and durable last turn;
                // a previously saved UI snapshot is not an authoritative source.
                // Reading this contract never loads the child or submits a turn.
                let stored = self
                    .store
                    .read_thread(codex_thread_store::ReadThreadParams {
                        thread_id: id,
                        include_archived: true,
                        include_history: true,
                    })
                    .await?;
                ensure!(stored.thread_id == id, "cold child identity changed");
                let SessionSource::SubAgent(SubAgentSource::ThreadSpawn {
                    parent_thread_id,
                    depth,
                    agent_nickname,
                    agent_role,
                    ..
                }) = &stored.source
                else {
                    bail!("cold child has no spawn owner")
                };
                ensure!(
                    stored
                        .parent_thread_id
                        .is_none_or(|parent| parent == *parent_thread_id),
                    "cold child owner is inconsistent"
                );
                let (status, preview) = stored
                    .history
                    .as_ref()
                    .and_then(|history| durable_summary(&history.items, "notLoaded"))
                    .unwrap_or(("notLoaded", None));
                let timing = crate::descendant_timing::Timing::from_stored(&stored).await;
                NativeSubagent {
                    thread_id: id.to_string(),
                    parent_thread_id: Some(parent_thread_id.to_string()),
                    nickname: stored.agent_nickname.or_else(|| agent_nickname.clone()),
                    role: stored.agent_role.or_else(|| agent_role.clone()),
                    depth: Some(*depth),
                    model: stored.model,
                    reasoning_effort: stored.reasoning_effort.map(|value| value.to_string()),
                    status: status.to_owned(),
                    loaded: false,
                    preview,
                    objective: None,
                    recency_at_ms: Some(stored.recency_at.timestamp_millis()),
                    started_at_ms: timing.started_at_ms,
                    last_assistant_message_at_ms: timing.last_assistant_message_at_ms,
                }
            };
            if closed.contains(&id) {
                row.status = "shutdown".to_owned();
            }
            rows.push(row);
        }
        // A fork can inherit its parent's user messages; those are never proof
        // of the delegated objective. Read public collaboration records from
        // each immediate owner's durable history, once per owner. The final
        // parent check excludes inherited calls to another owner's children.
        let owners: HashSet<_> = rows
            .iter()
            .filter_map(|row| row.parent_thread_id.as_deref())
            .filter_map(|id| ThreadId::from_string(id).ok())
            .collect();
        for owner in owners {
            if let Ok(thread) = self.manager.get_thread(owner).await {
                thread.flush_rollout().await?;
            }
            let Ok(history) = self
                .store
                .load_history(codex_thread_store::LoadThreadHistoryParams {
                    thread_id: owner,
                    include_archived: true,
                })
                .await
            else {
                continue;
            };
            ensure!(
                history.thread_id == owner,
                "objective owner identity changed"
            );
            let objectives = delegation_objectives(owner, &history.items);
            for row in &mut rows {
                if row.parent_thread_id.as_deref() == Some(&owner.to_string()) {
                    row.objective = ThreadId::from_string(&row.thread_id)
                        .ok()
                        .and_then(|child| objectives.get(&child).cloned());
                }
            }
        }
        rows.sort_by(|a, b| a.thread_id.cmp(&b.thread_id));
        Ok(rows)
    }

    /// Native close_agent marks the spawn edge before releasing the in-memory
    /// thread. An ordinary unloaded thread has an open edge and remains resumable.
    /// Open traversal also excludes children below a closed ancestor.
    async fn closed_descendants(&self) -> Result<HashSet<ThreadId>> {
        let Some(graph) = &self.graph else {
            return Ok(HashSet::new());
        };
        let all = graph
            .list_thread_spawn_descendants(self.parent, None)
            .await?;
        let open: HashSet<_> = graph
            .list_thread_spawn_descendants(
                self.parent,
                Some(codex_agent_graph_store::ThreadSpawnEdgeStatus::Open),
            )
            .await?
            .into_iter()
            .collect();
        Ok(all.into_iter().filter(|id| !open.contains(id)).collect())
    }
}

fn delegation_objectives(
    owner: ThreadId,
    items: &[codex_history::RolloutItem],
) -> HashMap<ThreadId, String> {
    use codex_core_api::EventMsg;
    use codex_protocol::{items::TurnItem, models::ResponseItem};
    let mut objectives = HashMap::new();
    let mut calls = HashMap::new();
    for item in items {
        if let codex_history::RolloutItem::ResponseItem(entry) = item {
            match &entry.item {
                ResponseItem::FunctionCall {
                    name,
                    namespace,
                    arguments,
                    call_id,
                    ..
                } => {
                    calls.remove(call_id);
                    if matches!(namespace.as_deref(), None | Some("multi_agent_v1"))
                        && matches!(name.as_str(), "spawn_agent" | "send_input")
                        && let Ok(args) = serde_json::from_str::<serde_json::Value>(arguments)
                    {
                        let prompt = args["message"].as_str().map(str::to_owned).or_else(|| {
                            args["items"].as_array().map(|items| {
                                items
                                    .iter()
                                    .filter(|item| item["type"] == "text")
                                    .filter_map(|item| item["text"].as_str())
                                    .collect::<Vec<_>>()
                                    .join("\n")
                            })
                        });
                        if let Some(prompt) = prompt.filter(|text| !text.trim().is_empty()) {
                            calls.insert(
                                call_id.clone(),
                                (
                                    name.clone(),
                                    prompt,
                                    args["target"]
                                        .as_str()
                                        .and_then(|id| ThreadId::from_string(id).ok()),
                                ),
                            );
                        }
                    }
                }
                ResponseItem::FunctionCallOutput {
                    call_id: Some(call),
                    output,
                    ..
                } => {
                    if let Some((name, prompt, target)) = calls.remove(call)
                        && output.success != Some(false)
                        && let Some(text) = output.body.to_text()
                        && let Ok(result) = serde_json::from_str::<serde_json::Value>(&text)
                        && result.get("error").is_none()
                    {
                        let child = if name == "spawn_agent" {
                            result["agent_id"]
                                .as_str()
                                .and_then(|id| ThreadId::from_string(id).ok())
                        } else if result["submission_id"]
                            .as_str()
                            .is_some_and(|id| !id.is_empty())
                        {
                            target
                        } else {
                            None
                        };
                        if let Some(child) = child {
                            objectives.insert(child, prompt.chars().take(1024).collect());
                        }
                    }
                }
                _ => {}
            }
            continue;
        }
        let codex_history::RolloutItem::EventMsg(event) = item else {
            continue;
        };
        if let EventMsg::TurnStarted(_) = event {
            calls.clear();
        }
        if let EventMsg::ItemCompleted(event) = event
            && event.thread_id == owner
            && let TurnItem::CollabAgentToolCall(call) = &event.item
            && call.sender_thread_id == owner
            && let Some(prompt) = call.prompt.as_ref().filter(|text| !text.trim().is_empty())
        {
            for child in &call.receiver_thread_ids {
                objectives.insert(*child, prompt.chars().take(1024).collect());
            }
            continue;
        }
        let (sender, child, prompt) = match event {
            EventMsg::CollabAgentSpawnEnd(event) => {
                (event.sender_thread_id, event.new_thread_id, &event.prompt)
            }
            EventMsg::CollabAgentInteractionBegin(event) => (
                event.sender_thread_id,
                Some(event.receiver_thread_id),
                &event.prompt,
            ),
            EventMsg::CollabAgentInteractionEnd(event) => (
                event.sender_thread_id,
                Some(event.receiver_thread_id),
                &event.prompt,
            ),
            _ => continue,
        };
        if sender == owner
            && !prompt.trim().is_empty()
            && let Some(child) = child
        {
            objectives.insert(child, prompt.chars().take(1024).collect());
        }
    }
    objectives
}

/// The newest turn boundary wins. A cold unfinished turn is unloaded, not a
/// fabricated running process; an explicitly resumed idle queue is interrupted.
fn durable_summary(
    items: &[codex_history::RolloutItem],
    unfinished: &'static str,
) -> Option<(&'static str, Option<String>)> {
    items.iter().rev().find_map(|item| match item {
        codex_history::RolloutItem::EventMsg(codex_core_api::EventMsg::TurnComplete(event)) => {
            Some((
                if event.error.is_some() {
                    "failed"
                } else {
                    "completed"
                },
                event
                    .last_agent_message
                    .as_ref()
                    .map(|text| text.chars().take(1024).collect()),
            ))
        }
        codex_history::RolloutItem::EventMsg(codex_core_api::EventMsg::TurnAborted(_)) => {
            Some(("interrupted", None))
        }
        codex_history::RolloutItem::EventMsg(codex_core_api::EventMsg::TurnStarted(_)) => {
            Some((unfinished, None))
        }
        _ => None,
    })
}

/// Shared by durable replay and live fanout so private context cannot leak via
/// a different presentation channel.
pub fn public_descendant_event(
    event: codex_core_api::EventMsg,
) -> Result<Option<serde_json::Value>> {
    use codex_core_api::EventMsg;
    if matches!(
        event,
        EventMsg::AgentReasoningRawContent(_)
            | EventMsg::ReasoningRawContentDelta(_)
            | EventMsg::SessionConfigured(_)
    ) {
        return Ok(None);
    }
    let mut value = serde_json::to_value(event)?;
    if value["type"] == "raw_response_item" {
        if !sanitize_response(&mut value["item"]) {
            return Ok(None);
        }
    } else if matches!(
        value["type"].as_str(),
        Some("item_started" | "item_completed")
    ) && value["item"]["type"] == "Reasoning"
        && let Some(fields) = value["item"].as_object_mut()
    {
        fields.remove("raw_content");
    }
    Ok(Some(value))
}

fn sanitize_response(value: &mut serde_json::Value) -> bool {
    if matches!(value["role"].as_str(), Some("developer" | "system"))
        || matches!(
            value["type"].as_str(),
            Some("configuration_update" | "compaction_trigger")
        )
    {
        return false;
    }
    if let Some(fields) = value.as_object_mut() {
        fields.remove("encrypted_content");
        fields.remove("internal_chat_message_metadata_passthrough");
        if fields.get("type").and_then(|v| v.as_str()) == Some("reasoning") {
            fields.remove("content");
        }
    }
    true
}

#[cfg(test)]
mod presentation_tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn objectives_use_only_owned_public_collaboration_and_latest_nonblank_prompt() -> Result<()> {
        let owner = ThreadId::new();
        let child = ThreadId::new();
        let peer = ThreadId::new();
        let interaction = |sender, target, text: &str| -> Result<_> {
            Ok(codex_history::RolloutItem::EventMsg(
                serde_json::from_value(json!({
                    "type":"collab_agent_interaction_begin", "call_id":"send", "sender_thread_id":sender,
                    "receiver_thread_id":target, "prompt":text
                }))?,
            ))
        };
        let spawn = codex_history::RolloutItem::EventMsg(serde_json::from_value(json!({
            "type":"collab_agent_spawn_end", "call_id":"spawn", "sender_thread_id":owner,
            "new_thread_id":child, "prompt":"Original objective", "model":"gpt-5.4",
            "reasoning_effort":"medium", "status":"running"
        }))?);
        let private = codex_history::RolloutItem::EventMsg(serde_json::from_value(json!({
            "type":"agent_reasoning_raw_content", "text":"Never an objective"
        }))?);
        let items = vec![
            spawn,
            interaction(owner, peer, "Peer objective")?,
            interaction(owner, child, "# **Updated** 检查🙂")?,
            interaction(owner, child, " \n\t")?,
            interaction(peer, child, "Inherited foreign-owner prompt")?,
            private,
        ];
        let result = delegation_objectives(owner, &items);
        assert_eq!(result.len(), 2);
        assert_eq!(result[&child], "# **Updated** 检查🙂");
        assert_eq!(result[&peer], "Peer objective");
        let long = "🙂".repeat(1100);
        let result = delegation_objectives(owner, &[interaction(owner, child, &long)?]);
        assert_eq!(result[&child].chars().count(), 1024);
        Ok(())
    }

    #[test]
    fn durable_objectives_pair_successful_legacy_calls_and_validate_paginated_owners() -> Result<()>
    {
        use codex_history::RolloutItem;
        let owner = ThreadId::new();
        let child = ThreadId::new();
        let foreign = ThreadId::new();
        let response = |value| -> Result<_> {
            let item: codex_protocol::models::ResponseItem = serde_json::from_value(value)?;
            Ok(RolloutItem::ResponseItem(item.into()))
        };
        let call = |id, name, namespace, args: serde_json::Value| {
            response(json!({
                "type":"function_call", "name":name, "namespace":namespace,
                "call_id":id, "arguments":args.to_string()
            }))
        };
        let output = |id, value: serde_json::Value| {
            response(json!({
                "type":"function_call_output", "call_id":id, "output":value.to_string()
            }))
        };
        let paginated = |sender, text| -> Result<_> {
            Ok(RolloutItem::EventMsg(serde_json::from_value(json!({
                "type":"item_completed", "thread_id":owner, "turn_id":"turn", "item":{
                    "type":"CollabAgentToolCall", "id":"c", "tool":"send_input", "status":"completed",
                    "sender_thread_id":sender, "receiver_thread_ids":[child], "prompt":text
                }
            }))?))
        };
        let mut items = vec![
            call(
                "spawn",
                "spawn_agent",
                "multi_agent_v1",
                json!({"message":"First objective"}),
            )?,
            output("unmatched", json!({"agent_id":child}))?,
            output("spawn", json!({"agent_id":child}))?,
            call(
                "bad",
                "spawn_agent",
                "mcp__unrelated",
                json!({"message":"Wrong namespace"}),
            )?,
            output("bad", json!({"agent_id":child}))?,
            call(
                "send",
                "send_input",
                "multi_agent_v1",
                json!({"target":child,"items":[{"type":"text","text":"Updated 🙂"}]}),
            )?,
            output("send", json!({"submission_id":"accepted"}))?,
            call(
                "failed",
                "send_input",
                "multi_agent_v1",
                json!({"target":child,"message":"Failed update"}),
            )?,
            output("failed", json!({"error":"not accepted"}))?,
            paginated(foreign, "Foreign owner must not override")?,
        ];
        items.push(call(
            "reused",
            "spawn_agent",
            "multi_agent_v1",
            json!({"message":"Stale call"}),
        )?);
        items.push(call(
            "reused",
            "spawn_agent",
            "mcp__unrelated",
            json!({"message":"Foreign call"}),
        )?);
        items.push(output("reused", json!({"agent_id":child}))?);
        assert_eq!(delegation_objectives(owner, &items)[&child], "Updated 🙂");
        items.push(paginated(owner, "Typed durable objective")?);
        assert_eq!(
            delegation_objectives(owner, &items)[&child],
            "Typed durable objective"
        );
        Ok(())
    }

    #[test]
    fn live_projection_preserves_public_summary_and_removes_private_response_content() -> Result<()>
    {
        let hidden =
            serde_json::from_value(json!({"type":"agent_reasoning_raw_content","text":"private"}))?;
        assert!(public_descendant_event(hidden)?.is_none());
        let public = serde_json::from_value(json!({"type":"agent_reasoning","text":"public"}))?;
        assert_eq!(public_descendant_event(public)?.unwrap()["text"], "public");
        let item = serde_json::from_value(
            json!({"type":"item_completed","thread_id":"00000000-0000-4000-8000-000000000001",
            "turn_id":"turn","item":{"type":"Reasoning","id":"r",
            "summary_text":["public item"],"raw_content":["private item"]}}),
        )?;
        let projected = public_descendant_event(item)?.unwrap();
        assert_eq!(projected["item"]["summary_text"][0], "public item");
        assert!(projected["item"].get("raw_content").is_none());
        for role in ["system", "developer"] {
            let mut response = json!({"type":"message","role":role,"content":[]});
            assert!(!sanitize_response(&mut response));
        }
        let mut response = json!({"type":"reasoning","summary":[{"text":"public"}],
            "content":[{"text":"private"}],"encrypted_content":"encrypted private",
            "internal_chat_message_metadata_passthrough":"private metadata"});
        assert!(sanitize_response(&mut response));
        assert_eq!(response["summary"][0]["text"], "public");
        assert!(response.get("content").is_none());
        assert!(response.get("encrypted_content").is_none());
        assert!(
            response
                .get("internal_chat_message_metadata_passthrough")
                .is_none()
        );
        Ok(())
    }
}
