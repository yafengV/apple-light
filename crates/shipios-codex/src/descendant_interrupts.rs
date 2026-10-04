use codex_core_api::{Op, ThreadId, ThreadManager};
use codex_protocol::protocol::AgentStatus;
use std::sync::Arc;
use std::time::Duration;
use tokio::task::JoinSet;

#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct DescendantInterruptReport {
    pub interrupted: usize,
    pub failed: usize,
    pub timed_out: bool,
}

/// Discover the actual spawn subtree. Neither other root conversations nor
/// completed/cold descendants are restarted to service a stop request.
pub(crate) async fn interrupt_active_descendants(
    manager: Arc<ThreadManager>,
    parent: ThreadId,
) -> DescendantInterruptReport {
    interrupt_descendants(manager, parent, false).await
}

pub(crate) async fn interrupt_idle_descendants(
    manager: Arc<ThreadManager>,
    parent: ThreadId,
) -> DescendantInterruptReport {
    interrupt_descendants(manager, parent, true).await
}

async fn interrupt_descendants(
    manager: Arc<ThreadManager>,
    parent: ThreadId,
    idle_only: bool,
) -> DescendantInterruptReport {
    let mut report = DescendantInterruptReport::default();
    let mut jobs = JoinSet::new();
    let work = async {
        let descendants = match manager.list_agent_subtree_thread_ids(parent).await {
            Ok(ids) => ids,
            Err(_) => {
                report.failed += 1;
                return;
            }
        };
        for id in descendants.into_iter().filter(|id| *id != parent) {
            let manager = Arc::clone(&manager);
            jobs.spawn(async move {
                if idle_only {
                    let Ok(root) = manager.get_thread(parent).await else {
                        return Ok(false);
                    };
                    if matches!(
                        root.agent_status().await,
                        AgentStatus::Running | AgentStatus::PendingInit
                    ) {
                        return Ok(false);
                    }
                }
                let Ok(thread) = manager.get_thread(id).await else {
                    return Ok(false);
                };
                if !matches!(
                    thread.agent_status().await,
                    AgentStatus::Running | AgentStatus::PendingInit
                ) {
                    return Ok(false);
                }
                thread.submit(Op::Interrupt).await.map(|_| true)
            });
        }
        while let Some(result) = jobs.join_next().await {
            match result {
                Ok(Ok(true)) => report.interrupted += 1,
                Ok(Ok(false)) => {}
                Ok(Err(_)) | Err(_) => report.failed += 1,
            }
        }
    };
    if tokio::time::timeout(Duration::from_secs(10), work)
        .await
        .is_err()
    {
        report.timed_out = true;
        jobs.shutdown().await;
    }
    report
}
