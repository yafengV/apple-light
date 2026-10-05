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
use tokio::sync::broadcast;

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
}

/// A task-private manager view. The host owns one event reader per loaded child;
/// durable history and status discovery do not consume events.
#[derive(Clone)]
pub struct DescendantSource {
    manager: Arc<ThreadManager>,
    parent: ThreadId,
    store: Arc<dyn codex_thread_store::ThreadStore>,
}

impl DescendantSource {
    pub(crate) fn new(
        manager: Arc<ThreadManager>,
        parent: ThreadId,
        store: Arc<dyn codex_thread_store::ThreadStore>,
    ) -> Self {
        Self {
            manager,
            parent,
            store,
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
        let id = self.validate_member(child).await?;
        let thread = self.manager.get_thread(id).await?;
        let input = TurnInputRequest::user_input(vec![UserInput::Text {
            text,
            text_elements: Vec::new(),
        }]);
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
            let (status, preview) = match thread.agent_status().await {
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
        let mut rows = members
            .into_iter()
            .map(|id| {
                loaded
                    .remove(&id)
                    .map(|(_, row)| row)
                    .unwrap_or(NativeSubagent {
                        thread_id: id.to_string(),
                        parent_thread_id: None,
                        nickname: None,
                        role: None,
                        depth: None,
                        model: None,
                        reasoning_effort: None,
                        status: "notLoaded".to_owned(),
                        loaded: false,
                        preview: None,
                    })
            })
            .collect::<Vec<_>>();
        rows.sort_by(|a, b| a.thread_id.cmp(&b.thread_id));
        Ok(rows)
    }
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
