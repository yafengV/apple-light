use crate::{
    codex_bridge::{
        CodexApproval, CodexBridge, CodexBrowserResolution, CodexElicitation, CodexImage,
        CodexSubmit, CodexTextAttachment, CodexUserInputAnswer, StartThread,
    },
    local_environment,
    service::{RunRequest, Service},
};
use anyhow::Result;
use serde::Deserialize;
use serde_json::{Value, json};
use shipios_core::PROTOCOL_VERSION;
use std::{path::PathBuf, sync::Arc};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    sync::mpsc,
};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Initialize {
    protocol_version: u32,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RunId {
    run_id: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Cursor {
    run_id: String,
    #[serde(default)]
    after_sequence: u64,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Artifact {
    run_id: String,
    name: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct EnvironmentFile {
    file_name: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct EnvironmentList {
    #[serde(default)]
    project_path: Option<PathBuf>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CodexTask {
    task_id: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CodexSteer {
    task_id: String,
    expected_turn_id: String,
    text: String,
    #[serde(default)]
    images: Vec<CodexImage>,
    text_attachment: Option<CodexTextAttachment>,
}

fn error(id: Value, code: i32, message: &str) -> Value {
    json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message}})
}
fn response(id: Value, result: Value) -> Value {
    json!({"jsonrpc":"2.0","id":id,"result":result})
}

async fn dispatch(
    service: &Arc<Service>,
    codex: &Arc<CodexBridge>,
    input: Value,
    initialized: &mut bool,
) -> Option<Value> {
    let object = match input.as_object() {
        Some(x) => x,
        None => return Some(error(Value::Null, -32600, "expected a JSON-RPC object")),
    };
    let id = object.get("id").cloned();
    if object.get("jsonrpc").and_then(Value::as_str) != Some("2.0")
        || object.get("method").and_then(Value::as_str).is_none()
        || id
            .as_ref()
            .is_some_and(|v| !v.is_string() && !v.is_i64() && !v.is_u64())
    {
        return Some(error(Value::Null, -32600, "invalid JSON-RPC request"));
    }
    // This protocol's mutations require a request id. Notifications do not execute methods.
    let id = id?;
    let method = object["method"].as_str().unwrap();
    let params = object.get("params").cloned().unwrap_or(json!({}));
    if method == "initialize" {
        if *initialized {
            return Some(error(id, -32002, "already initialized"));
        }
        match serde_json::from_value::<Initialize>(params) {
            Ok(p) if p.protocol_version == PROTOCOL_VERSION => {
                *initialized = true;
                return Some(response(
                    id,
                    json!({"protocolVersion":PROTOCOL_VERSION,"serverVersion":env!("CARGO_PKG_VERSION"),
                    "capabilities":{"runKinds":["doctor","build"],"cancellation":true,"eventReplay":true,
                        "modelCalls":true,"codexEmbedded":true,"codexResponses":true,"codexEventReplay":false,
                        "uiVerification":false,"release":false,"reportExport":true,"artifactRead":true},
                    "project":service.config.project,"dataDirectory":service.config.data_dir}),
                ));
            }
            Ok(_) => return Some(error(id, -32003, "unsupported protocolVersion")),
            Err(_) => return Some(error(id, -32602, "initialize requires protocolVersion")),
        }
    }
    if !*initialized {
        return Some(error(id, -32001, "initialize first"));
    }
    let result: std::result::Result<Value, (i32, String)> = async {
        let invalid = || (-32602, "invalid method parameters".to_string());
        let failed = |e: anyhow::Error| (-32010, e.to_string());
        match method {
            "environment.list" => {
                let request: EnvironmentList =
                    serde_json::from_value(params).map_err(|_| invalid())?;
                let project = request
                    .project_path
                    .as_deref()
                    .unwrap_or(&service.config.project);
                if !project.is_absolute() {
                    return Err(invalid());
                }
                Ok(
                    serde_json::to_value(local_environment::list(project).map_err(failed)?)
                        .unwrap(),
                )
            }
            "environment.load" => {
                let request: EnvironmentFile =
                    serde_json::from_value(params).map_err(|_| invalid())?;
                Ok(serde_json::to_value(
                    local_environment::load(&service.config.project, &request.file_name)
                        .map_err(failed)?,
                )
                .unwrap())
            }
            "environment.save" => {
                let request: local_environment::SaveRequest =
                    serde_json::from_value(params).map_err(|_| invalid())?;
                Ok(serde_json::to_value(
                    local_environment::save(&service.config.project, request).map_err(failed)?,
                )
                .unwrap())
            }
            "config.get" => {
                if params != json!({}) {
                    return Err(invalid());
                }
                Ok(serde_json::to_value(&service.config).unwrap())
            }
            "project.inspect" => {
                if params != json!({}) {
                    return Err(invalid());
                }
                Ok(serde_json::to_value(
                    shipios_tools::project::inspect(&service.config.project).map_err(failed)?,
                )
                .unwrap())
            }
            "run.start" => {
                let request: RunRequest = serde_json::from_value(params).map_err(|_| invalid())?;
                Ok(serde_json::to_value(service.start(request).map_err(failed)?).unwrap())
            }
            "run.get" => {
                let p: RunId = serde_json::from_value(params).map_err(|_| invalid())?;
                Ok(serde_json::to_value(service.get(&p.run_id).map_err(failed)?).unwrap())
            }
            "run.list" => {
                if params != json!({}) {
                    return Err(invalid());
                }
                Ok(serde_json::to_value(service.list().map_err(failed)?).unwrap())
            }
            "run.cancel" => {
                let p: RunId = serde_json::from_value(params).map_err(|_| invalid())?;
                Ok(json!({"requested":service.cancel(&p.run_id).map_err(failed)?}))
            }
            "run.report" => {
                let p: RunId = serde_json::from_value(params).map_err(|_| invalid())?;
                service.report(&p.run_id).map_err(failed)
            }
            "artifact.get" => {
                let p: Artifact = serde_json::from_value(params).map_err(|_| invalid())?;
                service.artifact(&p.run_id, &p.name).map_err(failed)
            }
            "run.events" => {
                let p: Cursor = serde_json::from_value(params).map_err(|_| invalid())?;
                let events = service
                    .events(&p.run_id, p.after_sequence)
                    .map_err(failed)?;
                let cursor = events
                    .last()
                    .map(|e| e.sequence)
                    .unwrap_or(p.after_sequence);
                Ok(json!({"events":events,"nextSequence":cursor}))
            }
            "codex.thread.start" => {
                let p: StartThread = serde_json::from_value(params).map_err(|_| invalid())?;
                let codex = Arc::clone(codex);
                let thread = tokio::spawn(async move { codex.start(p).await })
                    .await
                    .map_err(|error| failed(error.into()))?
                    .map_err(failed)?;
                Ok(serde_json::to_value(thread).unwrap())
            }
            "codex.turn.submit" => {
                let p: CodexSubmit = serde_json::from_value(params).map_err(|_| invalid())?;
                Ok(json!({"turnId":codex.submit_with_attachments(p).await.map_err(failed)?}))
            }
            "codex.turn.compact" => {
                let p: CodexTask = serde_json::from_value(params).map_err(|_| invalid())?;
                codex.compact(&p.task_id).await.map_err(failed)?;
                Ok(json!({"submitted":true}))
            }
            "codex.turn.steer" => {
                let p: CodexSteer = serde_json::from_value(params).map_err(|_| invalid())?;
                let steered = codex
                    .steer_with_attachments(
                        &p.task_id,
                        p.expected_turn_id,
                        p.text,
                        p.images,
                        p.text_attachment,
                    )
                    .await
                    .map_err(failed)?;
                Ok(json!({"steered":steered}))
            }
            "codex.turn.interrupt" => {
                let p: CodexTask = serde_json::from_value(params).map_err(|_| invalid())?;
                codex.interrupt(&p.task_id).await.map_err(failed)?;
                Ok(json!({"interrupted":true}))
            }
            "codex.turn.approve" => {
                let p: CodexApproval = serde_json::from_value(params).map_err(|_| invalid())?;
                codex.approve(p).await.map_err(failed)?;
                Ok(json!({"resolved":true}))
            }
            "codex.elicitation.resolve" => {
                let p: CodexElicitation = serde_json::from_value(params).map_err(|_| invalid())?;
                codex.resolve_elicitation(p).await.map_err(failed)?;
                Ok(json!({"resolved":true}))
            }
            "codex.browser.resolve" => {
                let p: CodexBrowserResolution =
                    serde_json::from_value(params).map_err(|_| invalid())?;
                codex.resolve_browser(p).map_err(failed)?;
                Ok(json!({"resolved":true}))
            }
            "codex.turn.answer" => {
                let p: CodexUserInputAnswer =
                    serde_json::from_value(params).map_err(|_| invalid())?;
                codex.answer_user_input(p).await.map_err(failed)?;
                Ok(json!({"answered":true}))
            }
            "codex.thread.stop" => {
                let p: CodexTask = serde_json::from_value(params).map_err(|_| invalid())?;
                codex.stop(&p.task_id).await.map_err(failed)?;
                Ok(json!({"stopped":true}))
            }
            _ => Err((-32601, "method not found".into())),
        }
    }
    .await;
    Some(match result {
        Ok(value) => response(id, value),
        Err((code, message)) => error(id, code, &message),
    })
}

pub async fn serve(service: Arc<Service>) -> Result<()> {
    let codex = Arc::new(CodexBridge::new(
        service.config.data_dir.clone(),
        service.config.project.clone(),
    ));
    let (sender, mut receiver) = mpsc::channel::<Value>(128);
    let writer = tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        while let Some(value) = receiver.recv().await {
            stdout
                .write_all(serde_json::to_string(&value)?.as_bytes())
                .await?;
            stdout.write_all(b"\n").await?;
            stdout.flush().await?;
        }
        Ok::<_, anyhow::Error>(())
    });
    let mut events = service.subscribe();
    let outgoing = sender.clone();
    let event_task = tokio::spawn(async move {
        loop {
            match events.recv().await {
            Ok(event)=> if outgoing.send(json!({"jsonrpc":"2.0","method":"run.event","params":event})).await.is_err() {break;},
            Err(tokio::sync::broadcast::error::RecvError::Lagged(_))=> {
                if outgoing.send(json!({"jsonrpc":"2.0","method":"events.gap","params":{"message":"Replay with run.events from your last sequence."}})).await.is_err() {break;}
            }
            Err(_)=>break,
        }
        }
    });
    let mut codex_events = codex.subscribe();
    let codex_outgoing = sender.clone();
    let codex_event_task = tokio::spawn(async move {
        loop {
            match codex_events.recv().await {
                Ok(event) => {
                    if codex_outgoing.send(json!({"jsonrpc":"2.0","method":"codex.event","params":event})).await.is_err() { break; }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                    if codex_outgoing.send(json!({"jsonrpc":"2.0","method":"events.gap","params":{"source":"codex","message":"Codex event stream lagged."}})).await.is_err() { break; }
                }
                Err(_) => break,
            }
        }
    });
    let mut initialized = false;
    let mut stdin = BufReader::new(tokio::io::stdin());
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let mut interrupt = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())?;
    loop {
        let mut frame = Vec::new();
        let result = tokio::select! {
            _=terminate.recv()=>break,
            _=interrupt.recv()=>break,
            _=sender.closed()=>break,
            result=async {(&mut stdin).take(65537).read_until(b'\n',&mut frame).await} => result,
        };
        match result {
            Ok(0) => break,
            Ok(_) if frame.len() > 65536 => {
                let _ = sender
                    .send(error(Value::Null, -32600, "frame exceeds 64 KiB"))
                    .await;
                break;
            }
            Ok(_) => {}
            Err(e) => {
                eprintln!("stdin read failed: {e}");
                break;
            }
        }
        let reply = match serde_json::from_slice::<Value>(&frame) {
            Ok(value) => dispatch(&service, &codex, value, &mut initialized).await,
            Err(_) => Some(error(Value::Null, -32700, "parse error")),
        };
        if let Some(reply) = reply
            && sender.send(reply).await.is_err()
        {
            break;
        }
    }
    service.shutdown().await;
    codex.shutdown().await;
    event_task.abort();
    let _ = event_task.await;
    codex_event_task.abort();
    let _ = codex_event_task.await;
    drop(sender);
    // A client that stops reading must not keep the agent alive forever.
    let mut writer = writer;
    match tokio::time::timeout(std::time::Duration::from_secs(2), &mut writer).await {
        Ok(result) => result??,
        Err(_) => writer.abort(),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use shipios_core::config::{Config, Layer};
    #[tokio::test]
    async fn handshake_rejects_wrong_versions_and_invalid_requests() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let service = Arc::new(Service::new(Config::load(
            &temp.path().join("data"),
            temp.path(),
            false,
            Layer::default(),
        )?)?);
        let codex = Arc::new(CodexBridge::new(
            service.config.data_dir.clone(),
            service.config.project.clone(),
        ));
        let mut ready = false;
        let reply = dispatch(
            &service,
            &codex,
            json!({"jsonrpc":"2.0","id":1,"method":"run.list"}),
            &mut ready,
        )
        .await
        .unwrap();
        assert_eq!(reply["error"]["code"], -32001);
        let reply = dispatch(
            &service,
            &codex,
            json!({"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":99}}),
            &mut ready,
        )
        .await
        .unwrap();
        assert_eq!(reply["error"]["code"], -32003);
        assert!(!ready);
        let reply = dispatch(
            &service,
            &codex,
            json!({"jsonrpc":"2.0","id":3,"method":"initialize","params":{"protocolVersion":1}}),
            &mut ready,
        )
        .await
        .unwrap();
        assert_eq!(reply["result"]["capabilities"]["modelCalls"], true);
        assert!(ready);
        assert!(
            dispatch(
                &service,
                &codex,
                json!({"jsonrpc":"2.0","method":"run.start","params":{"kind":"doctor"}}),
                &mut ready
            )
            .await
            .is_none()
        );
        assert!(service.list()?.is_empty());
        Ok(())
    }
}
