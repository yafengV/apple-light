use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use shipios_core::{
    Event, Run, RunStatus,
    config::{Config, private_dir},
    store::Store,
};
use shipios_tools::{
    BuildRequest,
    process::{self, CommandSpec},
};
use std::sync::{Arc, Mutex};
use tokio::sync::{Notify, broadcast};
use tokio_util::sync::CancellationToken;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum RunRequest {
    Doctor,
    Build(BuildRequest),
}

pub struct Service {
    pub config: Config,
    store: Mutex<Store>,
    active: Mutex<Option<(String, CancellationToken)>>,
    events: broadcast::Sender<Event>,
    idle: Notify,
}

impl Service {
    pub fn new(config: Config) -> Result<Self> {
        let store = Store::open(&config.data_dir)?;
        let (events, _) = broadcast::channel(128);
        Ok(Self {
            config,
            store: Mutex::new(store),
            active: Mutex::new(None),
            events,
            idle: Notify::new(),
        })
    }
    pub fn get(&self, id: &str) -> Result<Run> {
        self.store.lock().unwrap().get(id)
    }
    pub fn list(&self) -> Result<Vec<Run>> {
        self.store.lock().unwrap().list()
    }
    pub fn events(&self, id: &str, after: u64) -> Result<Vec<Event>> {
        self.store.lock().unwrap().events(id, after)
    }
    pub fn subscribe(&self) -> broadcast::Receiver<Event> {
        self.events.subscribe()
    }

    pub fn start(self: &Arc<Self>, request: RunRequest) -> Result<Run> {
        let mut active = self.active.lock().unwrap();
        ensure!(
            active.is_none(),
            "another run is active; cancel it or wait for completion"
        );
        if let RunRequest::Build(build) = &request {
            build.command(&self.config, &self.config.data_dir.join("Artifacts"))?;
        }
        let kind = match request {
            RunRequest::Doctor => "doctor",
            RunRequest::Build(_) => "build",
        };
        let (run, event) = self.store.lock().unwrap().create(
            kind,
            &self.config.project,
            serde_json::to_value(&request)?,
        )?;
        let cancel = CancellationToken::new();
        *active = Some((run.id.clone(), cancel.clone()));
        self.emit(event);
        let service = Arc::clone(self);
        let id = run.id.clone();
        tokio::spawn(async move {
            if let Err(error) = service.execute(&id, request, cancel.clone()).await {
                let status = if cancel.is_cancelled() {
                    RunStatus::Cancelled
                } else {
                    RunStatus::Failed
                };
                if let Err(persist_error) = service.transition(
                    &id,
                    status,
                    Some(json!({"errorCode":"EXECUTION_FAILED","message":error.to_string()})),
                ) {
                    eprintln!("failed to persist terminal run status: {persist_error}");
                }
            }
            // A completed run can already have been replaced by a new run.
            let mut active = service.active.lock().unwrap();
            if active
                .as_ref()
                .is_some_and(|(active_id, _)| *active_id == id)
            {
                *active = None;
            }
            drop(active);
            service.idle.notify_waiters();
        });
        Ok(run)
    }

    async fn execute(
        &self,
        id: &str,
        request: RunRequest,
        cancel: CancellationToken,
    ) -> Result<()> {
        self.transition(id, RunStatus::Running, None)?;
        let artifacts = private_dir(&self.config.data_dir.join("Artifacts").join(id))?;
        let (spec, project) = match request {
            RunRequest::Doctor => (
                CommandSpec {
                    executable: "/usr/bin/xcodebuild".into(),
                    args: vec!["-version".into()],
                    cwd: self.config.project.clone(),
                    env: self.config.tool_environment(),
                    timeout_seconds: 30,
                },
                Some(shipios_tools::project::inspect(&self.config.project)?),
            ),
            RunRequest::Build(build) => (build.command(&self.config, &artifacts)?, None),
        };
        let event = self.store.lock().unwrap().append(
            id,
            "step.started",
            json!({"executable":spec.executable,"arguments":spec.args}),
        )?;
        self.emit(event);
        let output = process::execute(spec, &artifacts, cancel).await?;
        let status = if output.cancelled {
            RunStatus::Cancelled
        } else if output.success() {
            RunStatus::Succeeded
        } else {
            RunStatus::Failed
        };
        self.transition(id,status,Some(json!({"command":output,"project":project,"artifactDirectory":artifacts,
            "verification":"not_run","note":"A successful diagnostic/build is not UI verification or release readiness."})))?;
        Ok(())
    }

    fn transition(&self, id: &str, status: RunStatus, result: Option<Value>) -> Result<()> {
        // Keep terminal status and the scheduler slot consistent for immediate reruns.
        let mut active = self.active.lock().unwrap();
        let event = self.store.lock().unwrap().transition(id, status, result)?;
        if status.terminal()
            && active
                .as_ref()
                .is_some_and(|(active_id, _)| active_id == id)
        {
            *active = None;
        }
        self.emit(event);
        Ok(())
    }

    pub fn report(&self, id: &str) -> Result<Value> {
        let run = self.get(id)?;
        ensure!(
            run.status.terminal(),
            "wait for the run to finish before exporting"
        );
        Ok(
            json!({"schemaVersion":1,"run":run,"events":self.events(id,0)?,
            "scope":"Local diagnostics/build only. No UI verification or model execution."}),
        )
    }

    pub fn artifact(&self, id: &str, name: &str) -> Result<Value> {
        use std::io::Read;
        self.get(id)?;
        ensure!(
            ["stdout.log", "stderr.log"].contains(&name),
            "unsupported artifact name"
        );
        let root = self
            .config
            .data_dir
            .join("Artifacts")
            .join(id)
            .canonicalize()?;
        let artifacts = self.config.data_dir.join("Artifacts").canonicalize()?;
        ensure!(
            root.starts_with(&artifacts),
            "artifact path escaped its root"
        );
        let path = root.join(name).canonicalize()?;
        ensure!(path.starts_with(&root), "artifact path escaped its run");
        let file = std::fs::File::open(&path)?;
        let size = file.metadata()?.len();
        let mut data = Vec::new();
        file.take(256 * 1024).read_to_end(&mut data)?;
        Ok(
            json!({"name":name,"text":String::from_utf8_lossy(&data),"truncated":size>data.len() as u64,"size":size}),
        )
    }
    fn emit(&self, event: Event) {
        let _ = self.events.send(event);
    }

    pub fn cancel(&self, id: &str) -> Result<bool> {
        let active = self.active.lock().unwrap();
        if let Some((active_id, token)) = &*active
            && id == active_id
        {
            token.cancel();
            return Ok(true);
        }
        self.get(id)?;
        Ok(false)
    }

    pub async fn wait_idle(&self) {
        loop {
            let notified = self.idle.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if self.active.lock().unwrap().is_none() {
                return;
            }
            notified.await;
        }
    }

    pub async fn shutdown(&self) {
        if let Some((_, token)) = &*self.active.lock().unwrap() {
            token.cancel();
        }
        self.wait_idle().await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use shipios_core::config::Layer;

    #[test]
    fn reports_and_artifacts_enforce_run_and_path_boundaries() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let service = Service::new(Config::load(
            &temp.path().join("data"),
            temp.path(),
            false,
            Layer::default(),
        )?)?;
        let (run, _) = service.store.lock().unwrap().create(
            "doctor",
            temp.path(),
            json!({"kind":"doctor"}),
        )?;
        assert!(service.report(&run.id).is_err());
        service.transition(&run.id, RunStatus::Running, None)?;
        *service.active.lock().unwrap() = Some((run.id.clone(), CancellationToken::new()));
        service.transition(&run.id, RunStatus::Succeeded, Some(json!({})))?;
        assert!(service.active.lock().unwrap().is_none());
        assert_eq!(service.report(&run.id)?["run"]["status"], "succeeded");
        let root = private_dir(&service.config.data_dir.join("Artifacts").join(&run.id))?;
        std::fs::write(root.join("stdout.log"), vec![b'x'; 300 * 1024])?;
        let artifact = service.artifact(&run.id, "stdout.log")?;
        assert_eq!(artifact["truncated"], true);
        assert_eq!(artifact["text"].as_str().unwrap().len(), 256 * 1024);
        assert!(service.artifact(&run.id, "../config.toml").is_err());
        assert!(service.artifact("unknown-run", "stdout.log").is_err());
        let outside = temp.path().join("outside.log");
        std::fs::write(&outside, "outside")?;
        std::os::unix::fs::symlink(outside, root.join("stderr.log"))?;
        assert!(service.artifact(&run.id, "stderr.log").is_err());
        Ok(())
    }
}
