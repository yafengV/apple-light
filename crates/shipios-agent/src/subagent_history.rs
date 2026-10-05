use anyhow::{Context, Result, ensure};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use shipios_codex::DescendantSource;
use std::{
    collections::HashMap,
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::Mutex;
use uuid::Uuid;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct HistoryRequest {
    pub task_id: String,
    pub expected_thread_id: String,
    pub child_thread_id: String,
    pub snapshot_id: Option<String>,
    #[serde(default)]
    pub offset: usize,
}

struct Snapshot {
    child: String,
    bytes: Arc<String>,
    digest: String,
    accessed: Instant,
}

/// Root-handle-owned immutable snapshots. Concurrent windows can finish their
/// own read while another refresh captures newer durable history.
#[derive(Default)]
pub(crate) struct HistorySnapshots(Mutex<HashMap<String, Snapshot>>);

impl HistorySnapshots {
    pub async fn read(&self, source: DescendantSource, request: HistoryRequest) -> Result<Value> {
        let child = source
            .validate_member(&request.child_thread_id)
            .await?
            .to_string();
        let id = if let Some(id) = request.snapshot_id {
            Uuid::parse_str(&id).context("invalid history snapshot ID")?;
            id
        } else {
            ensure!(request.offset == 0, "history must start at offset zero");
            let events = tokio::time::timeout(Duration::from_secs(10), source.history(&child))
                .await
                .context("child history read timed out")??;
            let bytes = serde_json::to_string(&events)?;
            let digest = format!("{:x}", Sha256::digest(bytes.as_bytes()));
            let id = Uuid::new_v4().to_string();
            let mut cache = self.0.lock().await;
            cache.retain(|_, v| v.accessed.elapsed() < Duration::from_secs(120));
            cache.insert(
                id.clone(),
                Snapshot {
                    child: child.clone(),
                    bytes: Arc::new(bytes),
                    digest,
                    accessed: Instant::now(),
                },
            );
            id
        };
        let mut cache = self.0.lock().await;
        let snapshot = cache
            .get_mut(&id)
            .context("child history snapshot expired; reload")?;
        ensure!(
            snapshot.child == child,
            "child history snapshot identity changed"
        );
        snapshot.accessed = Instant::now();
        let mut frame = history_frame(&id, &snapshot.bytes, &snapshot.digest, request.offset)?;
        frame["rootThreadId"] = json!(request.expected_thread_id);
        frame["childThreadId"] = json!(child);
        Ok(frame)
    }
}

fn history_frame(id: &str, bytes: &str, digest: &str, offset: usize) -> Result<Value> {
    ensure!(
        offset <= bytes.len() && bytes.is_char_boundary(offset),
        "invalid child history offset"
    );
    let mut end = offset.saturating_add(48 * 1024).min(bytes.len());
    while !bytes.is_char_boundary(end) {
        end -= 1;
    }
    Ok(
        json!({"snapshotId":id,"offset":offset,"nextOffset":end,"totalBytes":bytes.len(),
        "sha256":digest,"done":end == bytes.len(),"chunk":&bytes[offset..end]}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unicode_history_pages_are_complete_immutable_and_frame_bounded() -> Result<()> {
        let text = serde_json::to_string(&vec!["中文🙂\\\"".repeat(30_000)])?;
        let digest = format!("{:x}", Sha256::digest(text.as_bytes()));
        let mut offset = 0;
        let mut collected = String::new();
        let id = Uuid::new_v4().to_string();
        loop {
            let frame = history_frame(&id, &text, &digest, offset)?;
            assert_eq!(frame["offset"], offset);
            assert_eq!(frame["totalBytes"], text.len());
            assert!(serde_json::to_vec(&frame)?.len() < 512 * 1024);
            collected.push_str(frame["chunk"].as_str().unwrap());
            offset = frame["nextOffset"].as_u64().unwrap() as usize;
            if frame["done"] == true {
                break;
            }
        }
        assert_eq!(collected, text);
        assert_eq!(offset, text.len());
        assert!(history_frame(&id, &text, &digest, text.len() + 1).is_err());
        assert!(history_frame(&id, "🙂", &digest, 1).is_err());
        Ok(())
    }
}
