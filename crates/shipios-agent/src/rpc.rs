use crate::service::{RunRequest, Service};
use anyhow::Result;
use serde::Deserialize;
use serde_json::{Value, json};
use shipios_core::PROTOCOL_VERSION;
use std::sync::Arc;
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

fn error(id: Value, code: i32, message: &str) -> Value {
    json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message}})
}
fn response(id: Value, result: Value) -> Value {
    json!({"jsonrpc":"2.0","id":id,"result":result})
}

fn dispatch(service: &Arc<Service>, input: Value, initialized: &mut bool) -> Option<Value> {
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
                        "modelCalls":false,"codexEmbedded":false,"uiVerification":false,"release":false,"reportExport":true,"artifactRead":true},
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
    let result: std::result::Result<Value, (i32, String)> = (|| {
        let invalid = || (-32602, "invalid method parameters".to_string());
        let failed = |e: anyhow::Error| (-32010, e.to_string());
        match method {
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
            _ => Err((-32601, "method not found".into())),
        }
    })();
    Some(match result {
        Ok(value) => response(id, value),
        Err((code, message)) => error(id, code, &message),
    })
}

pub async fn serve(service: Arc<Service>) -> Result<()> {
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
            Ok(value) => dispatch(&service, value, &mut initialized),
            Err(_) => Some(error(Value::Null, -32700, "parse error")),
        };
        if let Some(reply) = reply
            && sender.send(reply).await.is_err()
        {
            break;
        }
    }
    service.shutdown().await;
    event_task.abort();
    let _ = event_task.await;
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
    #[test]
    fn handshake_rejects_wrong_versions_and_invalid_requests() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let service = Arc::new(Service::new(Config::load(
            &temp.path().join("data"),
            temp.path(),
            false,
            Layer::default(),
        )?)?);
        let mut ready = false;
        let reply = dispatch(
            &service,
            json!({"jsonrpc":"2.0","id":1,"method":"run.list"}),
            &mut ready,
        )
        .unwrap();
        assert_eq!(reply["error"]["code"], -32001);
        let reply = dispatch(
            &service,
            json!({"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":99}}),
            &mut ready,
        )
        .unwrap();
        assert_eq!(reply["error"]["code"], -32003);
        assert!(!ready);
        let reply = dispatch(
            &service,
            json!({"jsonrpc":"2.0","id":3,"method":"initialize","params":{"protocolVersion":1}}),
            &mut ready,
        )
        .unwrap();
        assert_eq!(reply["result"]["capabilities"]["modelCalls"], false);
        assert!(ready);
        assert!(
            dispatch(
                &service,
                json!({"jsonrpc":"2.0","method":"run.start","params":{"kind":"doctor"}}),
                &mut ready
            )
            .is_none()
        );
        assert!(service.list()?.is_empty());
        Ok(())
    }
}
