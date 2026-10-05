use serde_json::{Value, json};
use shipios_codex::{DescendantSource, NativeSubagent};
use std::{
    collections::{HashMap, HashSet},
    sync::Arc,
    time::Duration,
};
use tokio::{
    sync::{broadcast, watch},
    task::{JoinHandle, JoinSet},
};
use uuid::Uuid;

/// Owned by the root actor, but status discovery never delays its commands or
/// competes with the root event reader. One host reader fans out each loaded
/// child; native completion watchers use their independent status subscription.
pub(crate) struct DescendantMonitor {
    refresh: watch::Sender<Refresh>,
    worker: Option<JoinHandle<()>>,
}

#[derive(Clone, Default)]
struct Refresh {
    revision: u64,
    stopping: bool,
    submissions: HashMap<String, String>,
}

impl DescendantMonitor {
    pub fn start(
        source: DescendantSource,
        events: broadcast::Sender<Value>,
        task_id: String,
        root_thread_id: String,
        approvals: Arc<crate::subagent_approvals::SubagentApprovals>,
    ) -> Self {
        let mut created = source.subscribe_created();
        let (refresh, mut changes) = watch::channel(Refresh::default());
        let completed = refresh.clone();
        let worker = tokio::spawn(async move {
            let mut readers = JoinSet::new();
            let mut claimed = HashSet::new();
            let mut previous = None;
            let mut revision = 0_u64;
            let mut retry_or_active = true;
            let mut tick = tokio::time::interval(Duration::from_millis(500));
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                if changes.borrow().stopping {
                    // Shutdown has already asked native descendants to close.
                    // Give their final queued events a bounded drain, then drop
                    // JoinSet to abort any reader whose native shutdown failed.
                    let _ = tokio::time::timeout(Duration::from_secs(2), async {
                        while readers.join_next().await.is_some() {}
                    })
                    .await;
                    break;
                }
                tokio::select! {
                    _ = tick.tick(), if retry_or_active => {},
                    result = changes.changed() => {
                        if result.is_err() { break; }
                        previous = None;
                    },
                    _ = readers.join_next(), if !readers.is_empty() => { continue; },
                    result = created.recv() => {
                        if matches!(result, Err(broadcast::error::RecvError::Closed)) { break; }
                        // Lagged notifications require a complete rescan too.
                    },
                }
                if changes.borrow().stopping {
                    continue;
                }
                approvals.expire_closed(None).await;
                let pending = changes.borrow().submissions.clone();
                for (child, turn) in pending {
                    if matches!(
                        tokio::time::timeout(
                            Duration::from_secs(10),
                            source.submission_finished(&child, &turn)
                        )
                        .await,
                        Ok(Ok(true))
                    ) {
                        // Preserve a newer submission to this same child. Do
                        // not notify ourselves merely to remove a finished one.
                        completed.send_if_modified(|state| {
                            if state.submissions.get(&child) == Some(&turn) {
                                state.submissions.remove(&child);
                            }
                            false
                        });
                    }
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
                }) || !changes.borrow().submissions.is_empty();
                if previous.as_ref() != Some(&rows) {
                    revision += 1;
                    // Publish membership before any child reader can fan out.
                    for event in snapshot_frames(&rows, revision) {
                        let _ = events.send(json!({"taskId":task_id,
                            "threadId":root_thread_id,"event":event}));
                    }
                }
                claimed.retain(|id| rows.iter().any(|r| &r.thread_id == id && r.loaded));
                for row in &rows {
                    if !row.loaded || row.status == "shutdown" || claimed.contains(&row.thread_id) {
                        continue;
                    }
                    if let Ok(Ok(thread)) = tokio::time::timeout(
                        Duration::from_secs(10),
                        source.event_thread(&row.thread_id),
                    )
                    .await
                    {
                        claimed.insert(row.thread_id.clone());
                        let events = events.clone();
                        let task_id = task_id.clone();
                        let root_thread_id = root_thread_id.clone();
                        let child = row.thread_id.clone();
                        let approvals = Arc::clone(&approvals);
                        readers.spawn(async move {
                            let stream = Uuid::new_v4().to_string();
                            let mut sequence = 0_u64;
                            while let Ok(event) = thread.next_event().await {
                                let closed =
                                    matches!(event.msg, codex_core_api::EventMsg::ShutdownComplete);
                                let metadata = approvals
                                    .capture(&thread, &child, &event.msg)
                                    .await
                                    .ok()
                                    .flatten();
                                if matches!(
                                    event.msg,
                                    codex_core_api::EventMsg::TurnComplete(_)
                                        | codex_core_api::EventMsg::TurnAborted(_)
                                        | codex_core_api::EventMsg::ShutdownComplete
                                ) {
                                    approvals.expire_closed(Some(&child)).await;
                                }
                                if let Ok(Some(mut value)) =
                                    shipios_codex::public_descendant_event(event.msg)
                                {
                                    if let Some(metadata) = metadata {
                                        value["shipios_approval"] = metadata;
                                    }
                                    sequence += 1;
                                    for frame in live_event_frames(
                                        &child, &stream, sequence, &event.id, &value,
                                    ) {
                                        let _ = events.send(json!({"taskId":task_id,
                                            "threadId":root_thread_id,"event":frame}));
                                    }
                                }
                                if closed {
                                    break;
                                }
                            }
                        });
                    } else {
                        // A completion can race discovery. Keep retrying until
                        // this loaded queue is actually claimed or becomes cold.
                        retry_or_active = true;
                    }
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
        self.refresh
            .send_modify(|v| v.revision = v.revision.wrapping_add(1));
    }

    pub fn observe_submission(&self, child: String, turn: String) {
        self.refresh.send_modify(|state| {
            state.revision = state.revision.wrapping_add(1);
            state.submissions.insert(child, turn);
        });
    }

    pub async fn stop(mut self) {
        if let Some(worker) = self.worker.take() {
            self.refresh.send_modify(|v| v.stopping = true);
            let mut worker = worker;
            if tokio::time::timeout(Duration::from_secs(3), &mut worker)
                .await
                .is_err()
            {
                worker.abort();
                let _ = worker.await;
            }
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

fn live_event_frames(
    child: &str,
    stream: &str,
    sequence: u64,
    event_id: &str,
    event: &Value,
) -> Vec<Value> {
    use sha2::{Digest, Sha256};
    let bytes = serde_json::to_string(event).expect("JSON value serializes");
    let digest = format!("{:x}", Sha256::digest(bytes.as_bytes()));
    let mut offset = 0;
    let mut frames = Vec::new();
    while offset < bytes.len() {
        let mut end = offset.saturating_add(48 * 1024).min(bytes.len());
        while !bytes.is_char_boundary(end) {
            end -= 1;
        }
        frames.push(
            json!({"type":"shipios_subagent_event", "childThreadId":child,
            "streamId":stream,"sequence":sequence,"eventId":event_id,
            "offset":offset,"totalBytes":bytes.len(),"sha256":digest,
            "done":end == bytes.len(),"chunk":&bytes[offset..end]}),
        );
        offset = end;
    }
    frames
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
    fn live_frames_keep_child_event_identity_and_all_unicode_bytes() {
        let event = json!({"type":"agent_message","message":"中文🙂\\\"".repeat(30000)});
        let frames = live_event_frames(
            "child",
            &Uuid::new_v4().to_string(),
            42,
            "native-id",
            &event,
        );
        assert!(frames.len() > 1);
        let mut bytes = String::new();
        for frame in &frames {
            assert_eq!(frame["childThreadId"], "child");
            assert_eq!(frame["eventId"], "native-id");
            assert_eq!(frame["sequence"], 42);
            assert_eq!(frame["streamId"], frames[0]["streamId"]);
            assert_eq!(frame["offset"], bytes.len());
            assert!(serde_json::to_vec(frame).unwrap().len() < 512 * 1024);
            bytes.push_str(frame["chunk"].as_str().unwrap());
            assert_eq!(
                frame["done"],
                bytes.len() == frame["totalBytes"].as_u64().unwrap() as usize
            );
        }
        assert_eq!(serde_json::from_str::<Value>(&bytes).unwrap(), event);
        use sha2::{Digest, Sha256};
        assert_eq!(
            frames[0]["sha256"],
            format!("{:x}", Sha256::digest(bytes.as_bytes()))
        );
    }

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
