use codex_core_api::{EventMsg, ThreadId};
use codex_history::RolloutItem;
use codex_protocol::{items::TurnItem, models::ResponseItem};
use std::collections::HashMap;

#[derive(Default, Debug, PartialEq, Eq)]
pub(crate) struct Timing {
    pub started_at_ms: Option<i64>,
    pub last_assistant_message_at_ms: Option<i64>,
}

impl Timing {
    pub async fn from_stored(stored: &codex_thread_store::StoredThread) -> Self {
        let created = stored.created_at.timestamp_millis();
        if stored.history_mode == codex_protocol::protocol::ThreadHistoryMode::Paginated {
            // The store's replay vector deliberately omits record ordinals. Read
            // the native public record contract, including compressed rollouts,
            // so an inherited prefix (or a rejected record) cannot shift ownership.
            if let Some(path) = &stored.rollout_path
                && let Ok(items) = owned_paginated_items(path, stored.thread_id).await
            {
                return Self::from_history(stored.thread_id, &items, created);
            }
            return Self {
                started_at_ms: valid(Some(created)),
                ..Self::default()
            };
        }
        Self::from_history(
            stored.thread_id,
            stored
                .history
                .as_ref()
                .map_or(&[], |history| history.items.as_slice()),
            created,
        )
    }
    pub fn from_history(owner: ThreadId, items: &[RolloutItem], created_at_ms: i64) -> Self {
        let mut result = Self {
            started_at_ms: valid(Some(created_at_ms)),
            ..Self::default()
        };
        let mut turn = None;
        let mut turn_starts = HashMap::new();
        let mut message_starts = HashMap::new();
        for item in items {
            match item {
                RolloutItem::EventMsg(EventMsg::TurnStarted(event)) => {
                    let started = seconds(event.started_at);
                    turn = Some(event.turn_id.as_str());
                    turn_starts.insert(event.turn_id.as_str(), started);
                    result.started_at_ms = started.or(valid(Some(created_at_ms)));
                }
                RolloutItem::EventMsg(EventMsg::ItemStarted(event)) if event.thread_id == owner => {
                    if let TurnItem::AgentMessage(message) = &event.item {
                        let stamp = valid(Some(event.started_at_ms))
                            .or_else(|| turn_starts.get(event.turn_id.as_str()).copied().flatten());
                        message_starts.insert((event.turn_id.as_str(), message.id.as_str()), stamp);
                        result.last_assistant_message_at_ms = stamp;
                    }
                }
                RolloutItem::EventMsg(EventMsg::ItemCompleted(event))
                    if event.thread_id == owner =>
                {
                    if let TurnItem::AgentMessage(message) = &event.item {
                        let stamp = message_starts
                            .get(&(event.turn_id.as_str(), message.id.as_str()))
                            .copied()
                            .flatten()
                            .or(valid(event.started_at_ms))
                            .or_else(|| turn_starts.get(event.turn_id.as_str()).copied().flatten());
                        message_starts.insert((event.turn_id.as_str(), message.id.as_str()), stamp);
                        result.last_assistant_message_at_ms = stamp;
                    }
                }
                RolloutItem::EventMsg(EventMsg::AgentMessage(_)) => {
                    if let Some(current) = turn
                        && !message_starts.keys().any(|(turn, _)| *turn == current)
                    {
                        result.last_assistant_message_at_ms =
                            turn_starts.get(current).copied().flatten();
                    }
                }
                RolloutItem::ResponseItem(entry) => {
                    if let ResponseItem::Message { id, role, internal_chat_message_metadata_passthrough: metadata, .. } = &entry.item
                        && role == "assistant"
                        // Forked model context may carry a different turn identity.
                        && metadata.as_ref().and_then(|meta| meta.turn_id.as_deref())
                            .is_none_or(|id| Some(id) == turn)
                        && let Some(started) = turn.and_then(|id| turn_starts.get(id)).copied().flatten()
                    {
                        result.last_assistant_message_at_ms = id
                            .as_deref()
                            .and_then(|id| {
                                message_starts
                                    .get(&(turn.unwrap_or_default(), id))
                                    .copied()
                                    .flatten()
                            })
                            .or(Some(started));
                    }
                }
                _ => {}
            }
        }
        result
    }
}

async fn owned_paginated_items(
    path: &std::path::Path,
    owner: ThreadId,
) -> anyhow::Result<Vec<RolloutItem>> {
    let mut reader = codex_rollout::open_rollout_line_reader(path).await?;
    let mut boundary = None;
    let mut found_meta = false;
    let mut items = Vec::new();
    while let Some(line) = reader.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }
        let Ok(record) = codex_rollout::parse_rollout_line(&line) else {
            continue;
        };
        if !found_meta {
            let RolloutItem::SessionMeta(meta) = &record.item else {
                anyhow::bail!("timing history has no canonical metadata")
            };
            anyhow::ensure!(meta.meta.id == owner, "timing history identity changed");
            boundary = meta.meta.subagent_history_start_ordinal;
            found_meta = true;
        }
        let ordinal = record
            .ordinal
            .ok_or_else(|| anyhow::anyhow!("timing record has no ordinal"))?;
        if boundary.is_none_or(|start| ordinal >= start) {
            items.push(record.item);
        }
    }
    anyhow::ensure!(found_meta, "timing history is empty");
    Ok(items)
}

fn valid(value: Option<i64>) -> Option<i64> {
    value.filter(|value| *value >= 0)
}
fn seconds(value: Option<i64>) -> Option<i64> {
    valid(value).and_then(|value| value.checked_mul(1000))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn event(value: serde_json::Value) -> RolloutItem {
        RolloutItem::EventMsg(serde_json::from_value(value).unwrap())
    }
    fn start(id: &str, stamp: i64) -> RolloutItem {
        event(json!({"type":"task_started","turn_id":id,"started_at":stamp}))
    }
    fn message(turn: &str, role: &str) -> RolloutItem {
        serde_json::from_value(json!({"type":"response_item","payload":{"type":"message",
            "id":"answer","role":role,"content":[],"internal_chat_message_metadata_passthrough":{"turn_id":turn}}})).unwrap()
    }

    #[tokio::test]
    async fn paginated_boundary_uses_native_ordinals_even_when_a_record_is_rejected()
    -> anyhow::Result<()> {
        let owner = ThreadId::default();
        let root = tempfile::tempdir()?;
        let path = root.path().join("timing.jsonl");
        let meta = codex_protocol::protocol::SessionMeta {
            id: owner,
            subagent_history_start_ordinal: Some(20),
            history_mode: codex_protocol::protocol::ThreadHistoryMode::Paginated,
            ..Default::default()
        };
        let record = |ordinal, item: RolloutItem| {
            let mut value = serde_json::to_value(item).unwrap();
            value["ordinal"] = json!(ordinal);
            value["timestamp"] = json!("2026-10-07T00:00:00Z");
            value.to_string()
        };
        let metadata =
            RolloutItem::SessionMeta(codex_protocol::protocol::SessionMetaLine { meta, git: None });
        let lines = [
            record(0, metadata),
            record(3, start("inherited", 5)),
            record(4, message("inherited", "assistant")),
            "invalid record".to_owned(),
            record(20, start("own", 10)),
            record(21, message("own", "assistant")),
        ];
        std::fs::write(&path, lines.join("\n"))?;
        let own = owned_paginated_items(&path, owner).await?;
        assert_eq!(own.len(), 2);
        assert_eq!(
            Timing::from_history(owner, &own, 1),
            Timing {
                started_at_ms: Some(10000),
                last_assistant_message_at_ms: Some(10000)
            }
        );
        assert!(
            owned_paginated_items(&path, ThreadId::default())
                .await
                .is_err()
        );
        Ok(())
    }

    #[test]
    fn legacy_keeps_last_assistant_time_when_new_turn_has_not_replied() {
        let owner = ThreadId::default();
        let mut history = vec![
            start("first", 10),
            message("parent", "assistant"),
            message("first", "user"),
        ];
        assert_eq!(
            Timing::from_history(owner, &history, 1).last_assistant_message_at_ms,
            None
        );
        history.push(event(
            json!({"type":"agent_message","message":"Legacy public answer"}),
        ));
        assert_eq!(
            Timing::from_history(owner, &history, 1).last_assistant_message_at_ms,
            Some(10000)
        );
        history.push(message("first", "assistant"));
        history.push(start("retry", 20));
        assert_eq!(
            Timing::from_history(owner, &history, 1),
            Timing {
                started_at_ms: Some(20000),
                last_assistant_message_at_ms: Some(10000)
            }
        );
        history.push(message("retry", "assistant"));
        assert_eq!(
            Timing::from_history(owner, &history, 1).last_assistant_message_at_ms,
            Some(20000)
        );
        assert_eq!(
            Timing::from_history(owner, &[start("bad", i64::MAX)], 1).started_at_ms,
            Some(1)
        );
        assert_eq!(Timing::from_history(owner, &[], -1), Timing::default());
    }

    #[test]
    fn typed_messages_use_owned_item_start_instead_of_completion_or_poll_time() {
        let owner = ThreadId::default();
        let item = json!({"type":"AgentMessage","id":"answer","content":[]});
        let mut history = vec![
            start("first", 10),
            event(json!({"type":"item_started",
            "thread_id":owner,"turn_id":"first","item":item,"started_at_ms":10123})),
            event(
                json!({"type":"item_completed","thread_id":owner,"turn_id":"first",
                "item":item,"completed_at_ms":10999}),
            ),
        ];
        assert_eq!(
            Timing::from_history(owner, &history, 1).last_assistant_message_at_ms,
            Some(10123)
        );
        history.push(event(
            json!({"type":"item_completed","thread_id":ThreadId::default(),
            "turn_id":"foreign","item":item,"started_at_ms":20000,"completed_at_ms":20999}),
        ));
        assert_eq!(
            Timing::from_history(owner, &history, 1).last_assistant_message_at_ms,
            Some(10123)
        );
        history.push(message("first", "assistant"));
        assert_eq!(
            Timing::from_history(owner, &history, 1).last_assistant_message_at_ms,
            Some(10123)
        );
        history.push(start("retry", 20));
        history.push(message("retry", "assistant"));
        assert_eq!(
            Timing::from_history(owner, &history, 1).last_assistant_message_at_ms,
            Some(20000),
            "A reused message id in another turn must not borrow an old precise timestamp"
        );
    }
}
