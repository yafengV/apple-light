use serde_json::{Value, json};
use shipios_codex::{DescendantSource, NativeSubagent};
use std::time::Duration;
use tokio::{
    sync::{broadcast, watch},
    task::JoinHandle,
};
use uuid::Uuid;

/// Owned by the root actor, but status discovery never delays its commands or
/// consumes child events. After a root turn ends, active children keep polling.
pub(crate) struct DescendantMonitor {
    refresh: watch::Sender<u64>,
    worker: Option<JoinHandle<()>>,
}

impl DescendantMonitor {
    pub fn start(
        source: DescendantSource,
        events: broadcast::Sender<Value>,
        task_id: String,
        root_thread_id: String,
    ) -> Self {
        let mut created = source.subscribe_created();
        let (refresh, mut changes) = watch::channel(0_u64);
        let worker = tokio::spawn(async move {
            let mut previous = None;
            let mut revision = 0_u64;
            let mut retry_or_active = true;
            let mut tick = tokio::time::interval(Duration::from_millis(500));
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                tokio::select! {
                    _ = tick.tick(), if retry_or_active => {},
                    result = changes.changed() => {
                        if result.is_err() { break; }
                        previous = None;
                    },
                    result = created.recv() => {
                        if matches!(result, Err(broadcast::error::RecvError::Closed)) { break; }
                        // Lagged notifications require a complete rescan too.
                    },
                }
                let rows =
                    match tokio::time::timeout(Duration::from_secs(10), source.snapshot()).await {
                        Ok(Ok(rows)) => rows,
                        _ => {
                            retry_or_active = true;
                            continue;
                        }
                    };
                retry_or_active = rows.iter().any(|row| {
                    row.loaded && matches!(row.status.as_str(), "running" | "pendingInit")
                });
                if previous.as_ref() == Some(&rows) {
                    continue;
                }
                revision += 1;
                for event in snapshot_frames(&rows, revision) {
                    let _ = events.send(json!({"taskId":task_id,
                        "threadId":root_thread_id,"event":event}));
                }
                previous = Some(rows);
            }
        });
        Self {
            refresh,
            worker: Some(worker),
        }
    }

    pub fn refresh(&self) {
        self.refresh.send_modify(|v| *v = v.wrapping_add(1));
    }

    pub async fn stop(mut self) {
        if let Some(worker) = self.worker.take() {
            worker.abort();
            let _ = worker.await;
        }
    }
}

impl Drop for DescendantMonitor {
    fn drop(&mut self) {
        if let Some(worker) = &self.worker {
            worker.abort();
        }
    }
}

fn snapshot_frames(rows: &[NativeSubagent], revision: u64) -> Vec<Value> {
    let id = Uuid::new_v4().to_string();
    let observed_at_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;
    // Chunk the complete set rather than truncate the number of descendants.
    let chunks = rows.chunks(64).collect::<Vec<_>>();
    if chunks.is_empty() {
        return vec![json!({"type":"shipios_subagent_snapshot","snapshotId":id,
            "offset":0,"total":0,"done":true,"revision":revision,"observedAtMs":observed_at_ms,"agents":[]})];
    }
    chunks
        .iter()
        .enumerate()
        .map(|(index, chunk)| {
            json!({
                "type":"shipios_subagent_snapshot","snapshotId":id,
                "offset":index * 64,"total":rows.len(),"done":index + 1 == chunks.len(),
                "observedAtMs":observed_at_ms,"revision":revision,"agents":chunk,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snapshots_include_every_descendant_and_have_one_atomic_identity() {
        let rows = (0..193)
            .map(|i| NativeSubagent {
                thread_id: format!("child-{i}"),
                parent_thread_id: None,
                nickname: None,
                role: None,
                depth: None,
                model: None,
                reasoning_effort: None,
                status: "running".into(),
                loaded: true,
                preview: None,
            })
            .collect::<Vec<_>>();
        let frames = snapshot_frames(&rows, 17);
        assert_eq!(frames.len(), 4);
        let mut decoded = Vec::new();
        for frame in &frames {
            assert_eq!(frame["snapshotId"], frames[0]["snapshotId"]);
            assert_eq!(frame["observedAtMs"], frames[0]["observedAtMs"]);
            assert_eq!(frame["revision"], 17);
            assert_eq!(frame["total"], 193);
            assert_eq!(frame["offset"], decoded.len());
            decoded.extend(frame["agents"].as_array().unwrap().clone());
            assert_eq!(frame["done"], decoded.len() == 193);
        }
        assert_eq!(
            decoded,
            serde_json::to_value(rows)
                .unwrap()
                .as_array()
                .unwrap()
                .clone()
        );
        assert_ne!(
            frames[0]["snapshotId"],
            snapshot_frames(&[], 18)[0]["snapshotId"]
        );
        assert_eq!(snapshot_frames(&[], 18)[0]["done"], true);
    }
}
