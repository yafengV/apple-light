use anyhow::{Context, Result};
use serde::Deserialize;
use shipios_tools::process::{CommandSpec, execute};
use std::{io::Read, path::Path};
use tokio_util::sync::CancellationToken;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ScriptRequest {
    script: String,
    source: std::path::PathBuf,
    worktree: std::path::PathBuf,
    phase: Phase,
    timeout_seconds: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
enum Phase {
    Setup,
    Cleanup,
}

/// This mode intentionally never loads user/project Codex configuration or state.
pub async fn run(request_file: &Path) -> Result<()> {
    let request: ScriptRequest = serde_json::from_slice(
        &std::fs::read(request_file).context("read local environment request")?,
    )?;
    anyhow::ensure!(
        request.source.is_absolute() && request.worktree.is_absolute(),
        "absolute script paths required"
    );
    anyhow::ensure!(
        (1..=600).contains(&request.timeout_seconds),
        "invalid script timeout"
    );
    let artifacts = request_file
        .parent()
        .context("missing script log directory")?;
    let cancel = CancellationToken::new();
    let parent_cancel = cancel.clone();
    // EOF is also delivered when the desktop is SIGKILLed. A blocking reader
    // must not keep the runtime alive after an ordinary successful script exit.
    std::thread::spawn(move || {
        let mut input = std::io::stdin().lock();
        let mut buffer = [0; 256];
        while input.read(&mut buffer).is_ok_and(|count| count > 0) {}
        parent_cancel.cancel();
    });
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let signal_cancel = cancel.clone();
    let signals = tokio::spawn(async move {
        tokio::select! {
            _ = terminate.recv() => {},
            _ = tokio::signal::ctrl_c() => {},
        }
        signal_cancel.cancel();
    });
    let mut env = std::env::vars().collect::<std::collections::BTreeMap<_, _>>();
    env.insert(
        "CODEX_SOURCE_TREE_PATH".into(),
        request.source.display().to_string(),
    );
    env.insert(
        "CODEX_WORKTREE_PATH".into(),
        request.worktree.display().to_string(),
    );
    let result = execute(
        CommandSpec {
            executable: "/bin/zsh".into(),
            args: vec!["-l".into(), "-c".into(), request.script],
            cwd: match request.phase {
                Phase::Setup => request.worktree,
                Phase::Cleanup => request.source,
            },
            env,
            timeout_seconds: request.timeout_seconds,
        },
        artifacts,
        cancel,
    )
    .await;
    signals.abort();
    println!("{}", serde_json::to_string(&result?)?);
    Ok(())
}
