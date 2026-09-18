use anyhow::{Context, Result};
use serde::Serialize;
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    process::Stdio,
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWriteExt},
    process::Command,
};
use tokio_util::sync::CancellationToken;

pub struct CommandSpec {
    pub executable: PathBuf,
    pub args: Vec<String>,
    pub cwd: PathBuf,
    pub env: BTreeMap<String, String>,
    pub timeout_seconds: u64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandResult {
    pub exit_code: Option<i32>,
    pub termination_signal: Option<i32>,
    pub cancelled: bool,
    pub timed_out: bool,
    pub duration_ms: u64,
    pub stdout: String,
    pub stderr: String,
    pub output_truncated: bool,
    pub diagnostics: Vec<Diagnostic>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Diagnostic {
    pub severity: String,
    pub file: Option<String>,
    pub line: Option<u64>,
    pub message: String,
}

impl CommandResult {
    pub fn success(&self) -> bool {
        self.exit_code == Some(0) && !self.cancelled && !self.timed_out
    }
}

struct ProcessGroup(u32);
impl ProcessGroup {
    async fn stop(
        &self,
        child: &mut tokio::process::Child,
        xcode: bool,
    ) -> std::io::Result<std::process::ExitStatus> {
        // Xcode owns work in a separate build service. Let its client send the cancellation
        // message before falling back to process-group termination.
        unsafe {
            libc::kill(
                if xcode {
                    self.0 as i32
                } else {
                    -(self.0 as i32)
                },
                if xcode { libc::SIGINT } else { libc::SIGTERM },
            );
        }
        match tokio::time::timeout(Duration::from_secs(if xcode { 4 } else { 1 }), child.wait())
            .await
        {
            Ok(status) => status,
            Err(_) => {
                self.terminate();
                child.wait().await
            }
        }
    }
    fn terminate(&self) {
        // Each child is launched into its own group. Never signal our own group.
        if self.0 > 0 {
            unsafe {
                libc::kill(-(self.0 as i32), libc::SIGKILL);
            }
        }
    }
}
impl Drop for ProcessGroup {
    fn drop(&mut self) {
        self.terminate();
    }
}

/// Commands have no shell interpolation and inherit only an explicit environment.
pub async fn execute(
    spec: CommandSpec,
    artifacts: &Path,
    cancel: CancellationToken,
) -> Result<CommandResult> {
    if cancel.is_cancelled() {
        anyhow::bail!("operation cancelled before spawn");
    }
    let started = Instant::now();
    let mut command = Command::new(&spec.executable);
    command
        .args(&spec.args)
        .current_dir(&spec.cwd)
        .env_clear()
        .envs(&spec.env)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    command.process_group(0);
    let mut child = command
        .spawn()
        .with_context(|| format!("could not launch {}", spec.executable.display()))?;
    let group = ProcessGroup(child.id().context("missing child pid")?);
    let stdout = child.stdout.take().context("missing stdout")?;
    let stderr = child.stderr.take().context("missing stderr")?;
    let out_path = artifacts.join("stdout.log");
    let err_path = artifacts.join("stderr.log");
    let out_reader = tokio::spawn(capture(stdout, out_path));
    let err_reader = tokio::spawn(capture(stderr, err_path));
    let mut cancelled = false;
    let mut timed_out = false;
    let xcode = spec
        .executable
        .file_name()
        .is_some_and(|name| name == "xcodebuild");
    let status = tokio::select! {
        biased;
        _ = cancel.cancelled() => { cancelled=true; group.stop(&mut child, xcode).await? }
        _ = tokio::time::sleep(Duration::from_secs(spec.timeout_seconds)) => { timed_out=true; group.stop(&mut child, xcode).await? }
        status = child.wait() => status?,
    };
    // Also close pipes held by grandchildren after the leader has exited.
    group.terminate();
    let (stdout, out_truncated) = out_reader.await??;
    let (stderr, err_truncated) = err_reader.await??;
    // Disarm only after group cleanup to avoid signalling a recycled process id later.
    std::mem::forget(group);
    let diagnostics = parse_diagnostics(&format!("{stdout}\n{stderr}"));
    use std::os::unix::process::ExitStatusExt;
    Ok(CommandResult {
        exit_code: status.code(),
        termination_signal: status.signal(),
        cancelled,
        timed_out,
        duration_ms: started.elapsed().as_millis() as u64,
        stdout,
        stderr,
        output_truncated: out_truncated || err_truncated,
        diagnostics,
    })
}

async fn capture(mut input: impl AsyncRead + Unpin, path: PathBuf) -> Result<(String, bool)> {
    const LOG_LIMIT: usize = 4 * 1024 * 1024;
    const SUMMARY_LIMIT: usize = 64 * 1024;
    let mut file = tokio::fs::File::create(path).await?;
    let mut buffer = [0u8; 8192];
    let mut head = Vec::new();
    let mut tail = Vec::new();
    let mut total = 0;
    loop {
        let count = input.read(&mut buffer).await?;
        if count == 0 {
            break;
        }
        let allowed = count.min(LOG_LIMIT.saturating_sub(total));
        file.write_all(&buffer[..allowed]).await?;
        let kept = count.min((SUMMARY_LIMIT / 2).saturating_sub(head.len()));
        head.extend_from_slice(&buffer[..kept]);
        tail.extend_from_slice(&buffer[kept..count]);
        if tail.len() > SUMMARY_LIMIT / 2 {
            tail.drain(..tail.len() - SUMMARY_LIMIT / 2);
        }
        total = total.saturating_add(count);
    }
    if total > LOG_LIMIT {
        file.write_all(b"\n[ShipiOS: log truncated]\n").await?;
    }
    file.flush().await?;
    if total > SUMMARY_LIMIT {
        head.extend_from_slice(
            b"\n[ShipiOS: summary truncated; full bounded log is in the artifact directory]\n",
        );
    }
    head.extend(tail);
    Ok((
        String::from_utf8_lossy(&head).into_owned(),
        total > SUMMARY_LIMIT,
    ))
}

fn parse_diagnostics(text: &str) -> Vec<Diagnostic> {
    text.lines()
        .filter_map(|line| {
            let (prefix, severity, message) = if let Some((p, m)) = line.split_once(": error: ") {
                (p, "error", m)
            } else if let Some((p, m)) = line.split_once(": warning: ") {
                (p, "warning", m)
            } else {
                return None;
            };
            let mut location = prefix.rsplitn(3, ':');
            let column = location.next().and_then(|s| s.parse::<u64>().ok());
            let row = location.next().and_then(|s| s.parse::<u64>().ok());
            let path = location.next();
            let located = column.is_some() && row.is_some() && path.is_some();
            Some(Diagnostic {
                severity: severity.into(),
                file: if located {
                    path.map(str::to_owned)
                } else {
                    None
                },
                line: if located { row } else { None },
                message: message.into(),
            })
        })
        .take(100)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    fn spec(command: &str, root: &Path) -> CommandSpec {
        CommandSpec {
            executable: "/bin/sh".into(),
            args: vec!["-c".into(), command.into()],
            cwd: root.into(),
            env: BTreeMap::new(),
            timeout_seconds: 5,
        }
    }
    #[tokio::test]
    async fn process_status_and_environment_are_real() -> Result<()> {
        let tmp = tempfile::tempdir()?;
        let r=execute(spec("test -z \"$OPENAI_API_KEY\" && printf 'file.swift:8:2: error: intentional\\n'; exit 7",tmp.path()),tmp.path(),CancellationToken::new()).await?;
        assert_eq!(r.exit_code, Some(7));
        assert!(!r.success());
        assert_eq!(r.diagnostics[0].line, Some(8));
        Ok(())
    }
    #[tokio::test]
    async fn cancellation_and_timeout_stop_the_process_group() -> Result<()> {
        let tmp = tempfile::tempdir()?;
        let token = CancellationToken::new();
        let to_cancel = token.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(150)).await;
            to_cancel.cancel();
        });
        let r = execute(spec("sleep 30 & wait", tmp.path()), tmp.path(), token).await?;
        assert!(r.cancelled);
        assert!(r.duration_ms < 3000);
        let mut s = spec("sleep 30", tmp.path());
        s.timeout_seconds = 1;
        let r = execute(s, tmp.path(), CancellationToken::new()).await?;
        assert!(r.timed_out);
        assert!(r.duration_ms < 3000);
        Ok(())
    }

    #[tokio::test]
    async fn cancellation_allows_cooperative_cleanup() -> Result<()> {
        let tmp = tempfile::tempdir()?;
        let token = CancellationToken::new();
        let to_cancel = token.clone();
        let marker = tmp.path().join("ready");
        tokio::spawn(async move {
            for _ in 0..500 {
                if marker.exists() {
                    to_cancel.cancel();
                    return;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        });
        let r = execute(spec("trap 'echo stopped > cleanup; exit 0' TERM; touch ready; while :; do sleep 1; done", tmp.path()), tmp.path(), token).await?;
        assert!(r.cancelled);
        assert!(!r.success());
        let cleanup = tmp.path().join("cleanup");
        for _ in 0..500 {
            if cleanup.exists() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert_eq!(std::fs::read_to_string(cleanup)?.trim(), "stopped");
        Ok(())
    }

    #[tokio::test]
    async fn large_output_keeps_failure_at_tail_and_reports_signals() -> Result<()> {
        let tmp = tempfile::tempdir()?;
        let r = execute(
            spec("/usr/bin/yes x | /usr/bin/head -n 50000; printf 'tail.swift:12:3: error: final failure\\n'; exit 9", tmp.path()),
            tmp.path(), CancellationToken::new(),
        ).await?;
        assert!(r.output_truncated);
        assert!(r.stdout.len() < 66000);
        assert!(r.stdout.contains("final failure"));
        assert_eq!(r.diagnostics[0].line, Some(12));
        let r = execute(
            spec("kill -TERM $$", tmp.path()),
            tmp.path(),
            CancellationToken::new(),
        )
        .await?;
        assert_eq!(r.termination_signal, Some(15));
        assert!(!r.success());
        Ok(())
    }
}
