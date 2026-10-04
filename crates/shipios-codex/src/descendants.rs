use anyhow::Result;
use codex_core_api::{SessionSource, ThreadId, ThreadManager};
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

/// A task-private manager view; never consumes a child or root event stream.
#[derive(Clone)]
pub struct DescendantSource {
    manager: Arc<ThreadManager>,
    parent: ThreadId,
}

impl DescendantSource {
    pub(crate) fn new(manager: Arc<ThreadManager>, parent: ThreadId) -> Self {
        Self { manager, parent }
    }

    pub fn subscribe_created(&self) -> broadcast::Receiver<ThreadId> {
        self.manager.subscribe_thread_created()
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
