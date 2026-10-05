//! Root-owned, one-use responses to a child's original MCP waiter.
use anyhow::{Context, Result, ensure};
use codex_core_api::EventMsg;
use codex_protocol::approvals::ElicitationAction;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use shipios_codex::NativeElicitation;
use std::{collections::HashMap, sync::Arc};
use tokio::sync::{Mutex, broadcast};
use uuid::Uuid;

#[derive(Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Choice {
    Accept,
    AcceptForSession,
    Decline,
    Cancel,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Reply {
    pub task_id: String,
    pub expected_thread_id: String,
    pub child_thread_id: String,
    pub turn_id: String,
    pub request_token: String,
    pub choice: Choice,
    pub content: Option<Value>,
}

enum Kind {
    Form,
    Url,
    Tool,
}
struct Pending {
    child: String,
    turn: String,
    kind: Kind,
    choices: Vec<Choice>,
    reply: NativeElicitation,
}
#[derive(Default)]
struct State {
    revision: u64,
    pending: HashMap<String, Pending>,
}
pub(crate) struct SubagentElicitations {
    state: Mutex<State>,
    events: broadcast::Sender<Value>,
    task: String,
    root: String,
}

impl SubagentElicitations {
    pub fn new(events: broadcast::Sender<Value>, task: String, root: String) -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::default(),
            events,
            task,
            root,
        })
    }
    fn publish(
        &self,
        state: &mut State,
        token: &str,
        pending: &Pending,
        phase: &str,
        choice: Option<Choice>,
    ) {
        state.revision += 1;
        let _ = self.events.send(json!({"taskId":self.task,"threadId":self.root,
            "event":{"type":"shipios_subagent_elicitation_state","childThreadId":pending.child,
            "turnId":pending.turn,"requestToken":token,"revision":state.revision,"state":phase,"choice":choice}}));
    }
    pub async fn capture(
        &self,
        thread: &codex_core_api::CodexThread,
        child: &str,
        observed_turn: Option<&str>,
        event: &EventMsg,
    ) -> Result<Option<Value>> {
        let EventMsg::ElicitationRequest(request) = event else {
            return Ok(None);
        };
        let turn = observed_turn.context("child has no observed active turn")?;
        ensure!(
            request.turn_id.as_deref().is_none_or(|id| id == turn),
            "child elicitation turn changed"
        );
        let data = serde_json::to_value(&request.request)?;
        let generation = if request.turn_id.is_some() {
            Some(
                data["_meta"][shipios_codex::NATIVE_ELICITATION_GENERATION_KEY]
                    .as_u64()
                    .filter(|value| *value > 0)
                    .context("missing native elicitation generation")?,
            )
        } else {
            None
        };
        let kind = if data["_meta"]["codex_approval_kind"] == "mcp_tool_call"
            && request.turn_id.is_some()
        {
            Kind::Tool
        } else if data["mode"] == "url" {
            Kind::Url
        } else {
            Kind::Form
        };
        let choices = match kind {
            Kind::Tool => vec![
                Choice::Accept,
                Choice::AcceptForSession,
                Choice::Decline,
                Choice::Cancel,
            ],
            Kind::Url => vec![Choice::Accept, Choice::Cancel],
            Kind::Form => vec![Choice::Accept, Choice::Decline, Choice::Cancel],
        };
        let id = serde_json::from_value(serde_json::to_value(&request.id)?)?;
        // The sole reader owns a loaded Arc obtained through actual subtree validation.
        let reply = thread
            .claim_elicitation_for_turn(turn, &request.server_name, &id, generation)
            .await
            .context("native elicitation is no longer available")?;
        let token = Uuid::new_v4().to_string();
        let metadata = json!({"token":token,"turnId":turn,"choices":choices});
        let pending = Pending {
            child: child.to_owned(),
            turn: turn.to_owned(),
            kind,
            choices,
            reply,
        };
        let mut state = self.state.lock().await;
        self.publish(&mut state, &token, &pending, "pending", None);
        state.pending.insert(token, pending);
        Ok(Some(metadata))
    }
    pub async fn expire_closed(&self, child: Option<&str>) {
        let mut state = self.state.lock().await;
        let expired: Vec<_> = state
            .pending
            .iter()
            .filter(|(_, p)| p.reply.is_closed() || child == Some(p.child.as_str()))
            .map(|(token, _)| token.clone())
            .collect();
        for token in expired {
            if let Some(pending) = state.pending.remove(&token) {
                self.publish(&mut state, &token, &pending, "expired", None);
            }
        }
    }
    pub async fn resolve(&self, request: Reply) -> Result<Value> {
        ensure!(
            request.task_id == self.task && request.expected_thread_id == self.root,
            "elicitation task identity changed"
        );
        Uuid::parse_str(&request.request_token).context("invalid elicitation token")?;
        let (pending, action, content, meta) = {
            let mut state = self.state.lock().await;
            let pending = state
                .pending
                .get(&request.request_token)
                .context("elicitation is no longer available")?;
            ensure!(
                pending.child == request.child_thread_id && pending.turn == request.turn_id,
                "elicitation child or turn identity changed"
            );
            ensure!(
                pending.choices.contains(&request.choice),
                "invalid elicitation choice"
            );
            ensure!(
                request
                    .content
                    .as_ref()
                    .is_none_or(|value| value.is_object() && value.to_string().len() <= 65_536),
                "invalid elicitation content"
            );
            let (action, content, meta) = match request.choice {
                Choice::Accept => {
                    ensure!(
                        matches!(pending.kind, Kind::Form) || request.content.is_none(),
                        "unexpected elicitation content"
                    );
                    ensure!(
                        !matches!(pending.kind, Kind::Form) || request.content.is_some(),
                        "missing form content"
                    );
                    (
                        ElicitationAction::Accept,
                        Some(request.content.unwrap_or_else(|| json!({}))),
                        None,
                    )
                }
                Choice::AcceptForSession => {
                    ensure!(request.content.is_none(), "unexpected approval content");
                    (
                        ElicitationAction::Accept,
                        Some(json!({})),
                        Some(json!({"persist":"session"})),
                    )
                }
                Choice::Decline | Choice::Cancel => {
                    ensure!(request.content.is_none(), "unexpected declined content");
                    (
                        if request.choice == Choice::Decline {
                            ElicitationAction::Decline
                        } else {
                            ElicitationAction::Cancel
                        },
                        None,
                        None,
                    )
                }
            };
            let pending = state
                .pending
                .remove(&request.request_token)
                .expect("validated elicitation");
            self.publish(
                &mut state,
                &request.request_token,
                &pending,
                "resolving",
                Some(request.choice),
            );
            (pending, action, content, meta)
        };
        let Pending {
            child, turn, reply, ..
        } = pending;
        let resolved = reply.resolve(action, content, meta).await;
        let mut state = self.state.lock().await;
        state.revision += 1;
        let _ = self.events.send(json!({"taskId":self.task,"threadId":self.root,
            "event":{"type":"shipios_subagent_elicitation_state","childThreadId":child,"turnId":turn,
            "requestToken":request.request_token,"revision":state.revision,
            "state":if resolved {"resolved"} else {"expired"},"choice":request.choice}}));
        ensure!(resolved, "elicitation is no longer available");
        Ok(json!({"resolved":true}))
    }
}
