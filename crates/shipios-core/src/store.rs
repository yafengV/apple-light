use crate::{Event, Run, RunStatus, now_ms};
use anyhow::{Context, Result, ensure};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use std::{
    fs::{File, OpenOptions},
    path::Path,
};

pub struct Store {
    conn: Connection,
    _lock: File,
}

impl Store {
    pub fn open(data_dir: &Path) -> Result<Self> {
        use std::os::unix::fs::OpenOptionsExt;
        let state = data_dir.join("State");
        for name in [
            "agent.lock",
            "shipios.sqlite",
            "shipios.sqlite-wal",
            "shipios.sqlite-shm",
        ] {
            ensure!(
                !std::fs::symlink_metadata(state.join(name))
                    .is_ok_and(|m| m.file_type().is_symlink()),
                "state file must not be a symlink"
            );
        }
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(state.join("agent.lock"))?;
        lock.try_lock()
            .context("another ShipiOS agent is using this data directory")?;
        let conn = Connection::open(state.join("shipios.sqlite"))?;
        let version: i32 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        ensure!(
            version <= 1,
            "database was created by a newer ShipiOS version"
        );
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;
            CREATE TABLE IF NOT EXISTS runs (id TEXT PRIMARY KEY, body TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS events (run_id TEXT NOT NULL REFERENCES runs(id), sequence INTEGER NOT NULL, body TEXT NOT NULL, PRIMARY KEY(run_id, sequence));
            PRAGMA user_version=1;")?;
        let mut store = Self { conn, _lock: lock };
        // Never replay unknown external side effects on restart.
        for run in store.list()? {
            if !run.status.terminal() {
                store.transition(&run.id, RunStatus::Interrupted, Some(json!({"errorCode":"AGENT_RESTARTED", "message":"Agent stopped before recording a terminal result. Start a new run after inspecting artifacts."})))?;
            }
        }
        Ok(store)
    }

    pub fn create(&mut self, kind: &str, project: &Path, request: Value) -> Result<(Run, Event)> {
        let timestamp = now_ms();
        let run = Run {
            id: uuid::Uuid::new_v4().to_string(),
            kind: kind.into(),
            project: project.to_string_lossy().into_owned(),
            status: RunStatus::Queued,
            created_at: timestamp,
            updated_at: timestamp,
            request,
            result: None,
        };
        let tx = self.conn.transaction()?;
        tx.execute(
            "INSERT INTO runs(id,body) VALUES(?1,?2)",
            params![run.id, serde_json::to_string(&run)?],
        )?;
        let event = insert_event(&tx, &run.id, "run.queued", json!({"status":run.status}))?;
        tx.commit()?;
        Ok((run, event))
    }

    pub fn get(&self, id: &str) -> Result<Run> {
        let body: Option<String> = self
            .conn
            .query_row("SELECT body FROM runs WHERE id=?1", [id], |r| r.get(0))
            .optional()?;
        serde_json::from_str(&body.context("run not found")?).context("invalid stored run")
    }

    pub fn list(&self) -> Result<Vec<Run>> {
        let mut stmt = self
            .conn
            .prepare("SELECT body FROM runs ORDER BY rowid DESC")?;
        stmt.query_map([], |r| r.get::<_, String>(0))?
            .map(|body| Ok(serde_json::from_str(&body?)?))
            .collect()
    }

    pub fn transition(
        &mut self,
        id: &str,
        next: RunStatus,
        result: Option<Value>,
    ) -> Result<Event> {
        let mut run = self.get(id)?;
        ensure!(!run.status.terminal(), "run is already terminal");
        ensure!(
            matches!(
                (run.status, next),
                (
                    RunStatus::Queued,
                    RunStatus::Running | RunStatus::Cancelled | RunStatus::Interrupted
                ) | (
                    RunStatus::Running,
                    RunStatus::Succeeded
                        | RunStatus::Failed
                        | RunStatus::Cancelled
                        | RunStatus::Interrupted
                )
            ),
            "invalid run state transition"
        );
        run.status = next;
        run.updated_at = now_ms();
        run.result = result;
        let tx = self.conn.transaction()?;
        tx.execute(
            "UPDATE runs SET body=?2 WHERE id=?1",
            params![id, serde_json::to_string(&run)?],
        )?;
        let event = insert_event(
            &tx,
            id,
            if next.terminal() {
                "run.completed"
            } else {
                "run.started"
            },
            json!({"status":next, "result":run.result}),
        )?;
        tx.commit()?;
        Ok(event)
    }

    pub fn append(&mut self, id: &str, kind: &str, payload: Value) -> Result<Event> {
        ensure!(
            !self.get(id)?.status.terminal(),
            "cannot append to terminal run"
        );
        let tx = self.conn.transaction()?;
        let event = insert_event(&tx, id, kind, payload)?;
        tx.commit()?;
        Ok(event)
    }

    pub fn events(&self, id: &str, after: u64) -> Result<Vec<Event>> {
        self.get(id)?;
        ensure!(after <= i64::MAX as u64, "invalid event cursor");
        let mut stmt = self.conn.prepare(
            "SELECT body FROM events WHERE run_id=?1 AND sequence>?2 ORDER BY sequence LIMIT 1000",
        )?;
        stmt.query_map(params![id, after as i64], |r| r.get::<_, String>(0))?
            .map(|body| Ok(serde_json::from_str(&body?)?))
            .collect()
    }
}

fn insert_event(conn: &Connection, id: &str, kind: &str, payload: Value) -> Result<Event> {
    let sequence: i64 = conn.query_row(
        "SELECT COALESCE(MAX(sequence),0)+1 FROM events WHERE run_id=?1",
        [id],
        |r| r.get(0),
    )?;
    let event = Event {
        schema_version: 1,
        run_id: id.into(),
        sequence: sequence as u64,
        timestamp: now_ms(),
        kind: kind.into(),
        payload,
    };
    conn.execute(
        "INSERT INTO events(run_id,sequence,body) VALUES(?1,?2,?3)",
        params![id, sequence, serde_json::to_string(&event)?],
    )?;
    Ok(event)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, Layer};
    #[test]
    fn terminal_states_are_immutable_and_restart_marks_incomplete_runs() -> Result<()> {
        let tmp = tempfile::tempdir()?;
        let config = Config::load(
            &tmp.path().join("data"),
            tmp.path(),
            false,
            Layer::default(),
        )?;
        let mut db = Store::open(&config.data_dir)?;
        assert!(Store::open(&config.data_dir).is_err());
        let (run, _) = db.create("doctor", tmp.path(), json!({}))?;
        assert!(db.transition(&run.id, RunStatus::Succeeded, None).is_err());
        db.transition(&run.id, RunStatus::Running, None)?;
        drop(db);
        let mut db = Store::open(&config.data_dir)?;
        assert_eq!(db.get(&run.id)?.status, RunStatus::Interrupted);
        assert!(db.transition(&run.id, RunStatus::Running, None).is_err());
        let events = db.events(&run.id, 1)?;
        assert_eq!(
            events.iter().map(|e| e.sequence).collect::<Vec<_>>(),
            vec![2, 3]
        );
        Ok(())
    }
}
