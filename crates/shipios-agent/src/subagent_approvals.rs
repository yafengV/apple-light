//! Root-owned one-use replies to original native child approval waiters.
use anyhow::{Context, Result, ensure};
use codex_core_api::EventMsg;
use codex_protocol::protocol::ReviewDecision;
use serde::Deserialize;
use serde_json::{Value, json};
use shipios_codex::NativeApproval;
use std::{collections::HashMap, sync::Arc};
use tokio::sync::{Mutex, broadcast};
use uuid::Uuid;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ApprovalReply {
    pub task_id: String,
    pub expected_thread_id: String,
    pub child_thread_id: String,
    pub turn_id: String,
    pub request_token: String,
    pub choice: usize,
}

struct Pending {
    child: String,
    turn: String,
    decisions: Vec<ReviewDecision>,
    reply: NativeApproval,
}
#[derive(Default)]
struct State {
    revision: u64,
    pending: HashMap<String, Pending>,
}

pub(crate) struct SubagentApprovals {
    state: Mutex<State>,
    events: broadcast::Sender<Value>,
    task: String,
    root: String,
}
impl SubagentApprovals {
    pub fn new(events: broadcast::Sender<Value>, task: String, root: String) -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::default(),
            events,
            task,
            root,
        })
    }
    fn publish(&self, state: &mut State, token: &str, pending: &Pending, status: &str) {
        state.revision += 1;
        let _ = self.events.send(json!({"taskId":self.task,"threadId":self.root,
            "event":{"type":"shipios_subagent_approval_state","childThreadId":pending.child,
                "turnId":pending.turn,"requestToken":token,"revision":state.revision,"state":status}}));
    }
    pub async fn capture(
        &self,
        thread: &codex_core_api::CodexThread,
        child: &str,
        event: &EventMsg,
    ) -> Result<Option<Value>> {
        let (turn, id, stamp, decisions) = match event {
            EventMsg::ExecApprovalRequest(r) => (
                &r.turn_id,
                r.approval_id.as_deref().unwrap_or(&r.call_id),
                r.started_at_ms,
                r.effective_available_decisions(),
            ),
            EventMsg::ApplyPatchApprovalRequest(r) => (
                &r.turn_id,
                r.call_id.as_str(),
                r.started_at_ms,
                vec![
                    ReviewDecision::Approved,
                    ReviewDecision::ApprovedForSession,
                    ReviewDecision::Abort,
                ],
            ),
            _ => return Ok(None),
        };
        // This Arc was obtained by the root-owned reader through
        // DescendantSource.event_thread, which validates the actual subtree.
        // A loaded thread's source is immutable. Do not put another DB scan
        // between its approval event and claiming the original native waiter.
        let reply = thread
            .claim_approval_for_turn(turn, id, stamp)
            .await
            .context("native approval is no longer available")?;
        let token = Uuid::new_v4().to_string();
        let metadata = json!({"token":token,"decisions":decisions});
        let pending = Pending {
            child: child.to_owned(),
            turn: turn.to_owned(),
            decisions,
            reply,
        };
        let mut state = self.state.lock().await;
        self.publish(&mut state, &token, &pending, "pending");
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
                self.publish(&mut state, &token, &pending, "expired");
            }
        }
    }
    pub async fn resolve(&self, request: ApprovalReply) -> Result<Value> {
        ensure!(
            request.task_id == self.task && request.expected_thread_id == self.root,
            "approval task identity changed"
        );
        Uuid::parse_str(&request.request_token).context("invalid approval token")?;
        let (pending, decision) = {
            let mut state = self.state.lock().await;
            let pending = state
                .pending
                .get(&request.request_token)
                .context("approval is no longer available")?;
            ensure!(
                pending.child == request.child_thread_id && pending.turn == request.turn_id,
                "approval child or turn identity changed"
            );
            let decision = pending
                .decisions
                .get(request.choice)
                .context("invalid approval choice")?
                .clone();
            let pending = state
                .pending
                .remove(&request.request_token)
                .expect("validated approval");
            self.publish(&mut state, &request.request_token, &pending, "resolving");
            (pending, decision)
        };
        // No registry lock crosses native policy I/O, abort hooks or child execution.
        let result = pending.reply.resolve(decision).await;
        let mut state = self.state.lock().await;
        // NativeApproval is consumed. Keep only the identity needed for the receipt.
        state.revision += 1;
        let resolved = matches!(result, Ok(true));
        let _ = self.events.send(json!({"taskId":self.task,"threadId":self.root,
            "event":{"type":"shipios_subagent_approval_state","childThreadId":pending.child,
                "turnId":pending.turn,"requestToken":request.request_token,"revision":state.revision,
                "state":if resolved {"resolved"} else {"expired"}}}));
        ensure!(result?, "approval is no longer available");
        Ok(json!({"resolved":true}))
    }
}
