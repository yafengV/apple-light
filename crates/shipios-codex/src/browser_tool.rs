//! A native Codex tool that asks the owning macOS app to inspect its WebKit tabs.
//! The Agent cannot read a browser page directly or bypass the app's site policy.

use base64::Engine;
use codex_extension_api::{
    ExtensionData, FunctionCallError, JsonToolOutput, ResponsesApiTool, ToolCall, ToolContributor,
    ToolExecutor, ToolName, ToolOutput, ToolPayload, ToolSpec, parse_tool_input_schema,
};
use codex_protocol::models::{
    FunctionCallOutputBody, FunctionCallOutputContentItem, FunctionCallOutputPayload,
    ImageReference, ResponseInputItem,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::sync::{broadcast, oneshot};
use uuid::Uuid;

type Pending = Arc<Mutex<HashMap<String, (String, oneshot::Sender<Value>)>>>;

#[derive(Clone)]
pub struct BrowserToolBridge {
    task_id: String,
    events: broadcast::Sender<Value>,
    pending: Pending,
    screenshot_root: PathBuf,
}

impl BrowserToolBridge {
    pub fn new(events: broadcast::Sender<Value>, screenshot_root: PathBuf) -> Self {
        Self {
            task_id: String::new(),
            events,
            pending: Arc::new(Mutex::new(HashMap::new())),
            screenshot_root,
        }
    }

    pub fn for_task(&self, task_id: String) -> Self {
        Self {
            task_id,
            events: self.events.clone(),
            pending: Arc::clone(&self.pending),
            screenshot_root: self.screenshot_root.clone(),
        }
    }

    pub fn resolve(&self, task_id: &str, request_id: &str, result: Value) -> bool {
        let mut pending = self.pending.lock().expect("browser request lock");
        if pending
            .get(request_id)
            .is_none_or(|(owner, _)| owner != task_id)
        {
            return false;
        }
        if let Some((_, reply)) = pending.remove(request_id) {
            return reply.send(result).is_ok();
        }
        false
    }

    pub fn cancel_task(&self, task_id: &str) {
        self.pending
            .lock()
            .expect("browser request lock")
            .retain(|_, (owner, _)| owner != task_id);
    }

    async fn request(
        &self,
        action: &str,
        tab_id: Option<String>,
        url: Option<String>,
        handle: Option<String>,
        text: Option<String>,
        download_id: Option<String>,
    ) -> Result<(String, Value), String> {
        let request_id = Uuid::new_v4().to_string();
        let (reply, receiver) = oneshot::channel();
        self.pending
            .lock()
            .expect("browser request lock")
            .insert(request_id.clone(), (self.task_id.clone(), reply));
        let event = json!({
            "taskId": self.task_id,
            "event": {"type": "browser_request", "requestId": request_id,
                "action": action, "tabId": tab_id, "url": url,
                "handle": handle, "text": text, "downloadId": download_id}
        });
        if self.events.send(event).is_err() {
            self.pending
                .lock()
                .expect("browser request lock")
                .remove(&request_id);
            return Err("ShipiOS browser is not connected".to_owned());
        }
        let result = tokio::time::timeout(Duration::from_secs(90), receiver).await;
        self.pending
            .lock()
            .expect("browser request lock")
            .remove(&request_id);
        match result {
            Ok(Ok(value)) => Ok((request_id, value)),
            Ok(Err(_)) => Err("ShipiOS browser request was cancelled".to_owned()),
            Err(_) => Err("ShipiOS browser request timed out".to_owned()),
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BrowserArgs {
    action: String,
    tab_id: Option<String>,
    url: Option<String>,
    handle: Option<String>,
    text: Option<String>,
    download_id: Option<String>,
}

struct BrowserScreenshotOutput {
    image_url: String,
    tab_id: String,
}

impl ToolOutput for BrowserScreenshotOutput {
    fn log_output(&self) -> String {
        format!("Browser screenshot for tab {} (image omitted)", self.tab_id)
    }

    fn success_for_logging(&self) -> bool {
        true
    }

    fn contains_external_context(&self) -> bool {
        true
    }

    fn to_response_item(&self, call_id: &str, _payload: &ToolPayload) -> ResponseInputItem {
        ResponseInputItem::FunctionCallOutput {
            call_id: call_id.to_owned(),
            output: FunctionCallOutputPayload {
                body: FunctionCallOutputBody::ContentItems(vec![
                    FunctionCallOutputContentItem::InputText {
                        text: format!("Screenshot of browser tab {}", self.tab_id),
                    },
                    FunctionCallOutputContentItem::InputImage {
                        image: ImageReference::Inline {
                            image_url: self.image_url.clone(),
                        },
                        detail: None,
                    },
                ]),
                success: Some(true),
            },
        }
    }
}

fn staged_screenshot(
    root: &std::path::Path,
    request_id: &str,
    byte_count: u64,
) -> Result<String, String> {
    if Uuid::parse_str(request_id).is_err() {
        return Err("Invalid browser screenshot metadata".to_owned());
    }
    let file = root.join(format!("{request_id}.png"));
    let result = (|| {
        if !(1..=10 * 1024 * 1024).contains(&byte_count) {
            return Err("Invalid browser screenshot metadata".to_owned());
        }
        let directory = root
            .symlink_metadata()
            .map_err(|_| "Screenshot staging is unavailable")?;
        if !directory.file_type().is_dir() {
            return Err("Screenshot staging path is invalid".to_owned());
        }
        let metadata = file
            .symlink_metadata()
            .map_err(|_| "Screenshot file is unavailable")?;
        if !metadata.file_type().is_file() || metadata.len() != byte_count {
            return Err("Screenshot file changed".to_owned());
        }
        let bytes = std::fs::read(&file).map_err(|_| "Screenshot file could not be read")?;
        if bytes.len() as u64 != byte_count || !bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
            return Err("Screenshot file is invalid".to_owned());
        }
        Ok(format!(
            "data:image/png;base64,{}",
            base64::engine::general_purpose::STANDARD.encode(bytes)
        ))
    })();
    let _ = std::fs::remove_file(file);
    result
}

fn valid_browser_url(value: &str) -> bool {
    if value.len() > 2_048 {
        return false;
    }
    let Ok(url) = url::Url::parse(value) else {
        return false;
    };
    matches!(url.scheme(), "http" | "https")
        && url.username().is_empty()
        && url.password().is_none()
        && url.host_str().is_some()
}

pub struct BrowserToolContributor {
    bridge: BrowserToolBridge,
}

impl BrowserToolContributor {
    pub fn new(bridge: BrowserToolBridge) -> Self {
        Self { bridge }
    }
}

impl ToolContributor for BrowserToolContributor {
    fn tools(
        &self,
        _session_store: &ExtensionData,
        _thread_store: &ExtensionData,
    ) -> Vec<Arc<dyn for<'call> ToolExecutor<ToolCall<'call>>>> {
        vec![Arc::new(BrowserTool {
            bridge: self.bridge.clone(),
        })]
    }
}

struct BrowserTool {
    bridge: BrowserToolBridge,
}

impl<'call> ToolExecutor<ToolCall<'call>> for BrowserTool {
    fn tool_name(&self) -> ToolName {
        ToolName::plain("shipios_browser")
    }

    fn spec(&self) -> ToolSpec {
        ToolSpec::Function(ResponsesApiTool {
            name: "shipios_browser".to_owned(),
            description: "Use the task's ShipiOS browser. list returns tab IDs; open navigates to an http/https URL; read returns visible page text; screenshot returns the viewport as an image; inspect returns live element handles; click activates a handle; fill enters text; download starts a same-website download from an inspected link; download_status checks its progress; cancel_download stops it. Inspect again after navigation or page changes. ShipiOS checks website access and may ask the user where to save.".to_owned(),
            strict: false,
            parameters: parse_tool_input_schema(&json!({
                "type": "object",
                "properties": {
                    "action": {"type": "string", "enum": ["list", "read", "open", "screenshot", "inspect", "click", "fill", "download", "download_status", "cancel_download"]},
                    "tab_id": {"type": "string", "description": "Required for read, screenshot and inspect; use an ID returned by list."},
                    "url": {"type": "string", "description": "Required for open; absolute http/https URL."},
                    "handle": {"type": "string", "description": "Required for click, fill and download; use a handle returned by inspect."},
                    "text": {"type": "string", "description": "Required for fill; text to enter, at most 4000 characters."},
                    "download_id": {"type": "string", "description": "Required for download_status and cancel_download; use the ID returned by download."}
                },
                "required": ["action"],
                "additionalProperties": false
            }))
            .expect("browser schema"),
            output_schema: None,
            defer_loading: None,
        })
    }

    fn handle<'a>(&'a self, call: ToolCall<'call>) -> codex_extension_api::ToolExecutorFuture<'a>
    where
        'call: 'a,
    {
        Box::pin(async move {
            let args: BrowserArgs = serde_json::from_str(call.function_arguments()?)
                .map_err(|error| FunctionCallError::RespondToModel(error.to_string()))?;
            if !matches!(
                args.action.as_str(),
                "list"
                    | "read"
                    | "open"
                    | "screenshot"
                    | "inspect"
                    | "click"
                    | "fill"
                    | "download"
                    | "download_status"
                    | "cancel_download"
            ) || (matches!(
                args.action.as_str(),
                "read" | "screenshot" | "inspect" | "click" | "fill" | "download"
            ) && args
                .tab_id
                .as_ref()
                .is_none_or(|id| Uuid::parse_str(id).is_err()))
                || (args.action == "open"
                    && args
                        .url
                        .as_ref()
                        .is_none_or(|value| !valid_browser_url(value)))
                || (matches!(args.action.as_str(), "click" | "fill" | "download")
                    && args.handle.as_ref().is_none_or(|value| {
                        value.len() > 100 || !value.is_ascii() || !value.contains(':')
                    }))
                || (args.action == "fill"
                    && args
                        .text
                        .as_ref()
                        .is_none_or(|value| value.chars().count() > 4_000))
                || (matches!(args.action.as_str(), "download_status" | "cancel_download")
                    && args
                        .download_id
                        .as_ref()
                        .is_none_or(|id| Uuid::parse_str(id).is_err()))
            {
                return Err(FunctionCallError::RespondToModel(
                    "Use list, open with an http/https URL, read/screenshot/inspect with a tab_id, click/fill/download with a tab_id and inspected handle, or download_status/cancel_download with a download_id.".to_owned(),
                ));
            }
            let (request_id, result) = self
                .bridge
                .request(
                    &args.action,
                    args.tab_id.clone(),
                    args.url,
                    args.handle,
                    args.text,
                    args.download_id,
                )
                .await
                .map_err(FunctionCallError::RespondToModel)?;
            if args.action == "screenshot" && result["status"] == "ok" {
                let byte_count = result["byte_count"].as_u64().ok_or_else(|| {
                    FunctionCallError::RespondToModel("Screenshot size is missing".to_owned())
                })?;
                let image_url =
                    staged_screenshot(&self.bridge.screenshot_root, &request_id, byte_count)
                        .map_err(FunctionCallError::RespondToModel)?;
                if result["tab_id"].as_str() != args.tab_id.as_deref() {
                    return Err(FunctionCallError::RespondToModel(
                        "Screenshot belongs to a different tab".to_owned(),
                    ));
                }
                return Ok(Box::new(BrowserScreenshotOutput {
                    image_url,
                    tab_id: result["tab_id"].as_str().unwrap_or("").to_owned(),
                }) as Box<dyn ToolOutput>);
            }
            Ok(
                Box::new(JsonToolOutput::new(result).with_external_context())
                    as Box<dyn ToolOutput>,
            )
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn response_must_match_request_owner_and_cannot_be_reused() {
        let (events, mut receiver) = broadcast::channel(8);
        let bridge = BrowserToolBridge::new(events, PathBuf::new());
        let task = bridge.for_task("task-a".to_owned());
        let pending =
            tokio::spawn(async move { task.request("list", None, None, None, None, None).await });
        let event = receiver.recv().await.expect("request event");
        let id = event["event"]["requestId"].as_str().unwrap();
        assert_eq!(event["taskId"], "task-a");
        assert!(!bridge.resolve("task-b", id, json!({"status":"ok"})));
        assert!(bridge.resolve("task-a", id, json!({"status":"ok"})));
        assert_eq!(pending.await.unwrap().unwrap().1["status"], "ok");
        assert!(!bridge.resolve("task-a", id, json!({"status":"ok"})));
    }

    #[tokio::test]
    async fn stopping_a_task_cancels_its_pending_browser_request() {
        let (events, mut receiver) = broadcast::channel(8);
        let bridge = BrowserToolBridge::new(events, PathBuf::new());
        let task = bridge.for_task("task-a".to_owned());
        let pending = tokio::spawn(async move {
            task.request(
                "read",
                Some(Uuid::new_v4().to_string()),
                None,
                None,
                None,
                None,
            )
            .await
        });
        let event = receiver.recv().await.expect("request event");
        bridge.cancel_task("task-a");
        assert!(pending.await.unwrap().is_err());
        assert!(!bridge.resolve(
            "task-a",
            event["event"]["requestId"].as_str().unwrap(),
            json!({})
        ));
    }

    #[tokio::test]
    async fn download_status_forwards_only_the_requested_id_to_its_owner() {
        let (events, mut receiver) = broadcast::channel(8);
        let bridge = BrowserToolBridge::new(events, PathBuf::new());
        let id = Uuid::new_v4().to_string();
        let task = bridge.for_task("task-a".to_owned());
        let expected = id.clone();
        let pending = tokio::spawn(async move {
            task.request("download_status", None, None, None, None, Some(expected))
                .await
        });
        let event = receiver.recv().await.expect("download status request");
        assert_eq!(event["event"]["action"], "download_status");
        assert_eq!(event["event"]["downloadId"], id);
        let request_id = event["event"]["requestId"].as_str().unwrap();
        assert!(!bridge.resolve("task-b", request_id, json!({"status":"ok"})));
        assert!(bridge.resolve("task-a", request_id, json!({"status":"ok"})));
        assert_eq!(pending.await.unwrap().unwrap().1["status"], "ok");
    }

    #[test]
    fn open_only_accepts_short_http_urls_without_embedded_credentials() {
        assert!(valid_browser_url("https://example.com/path"));
        assert!(valid_browser_url("http://127.0.0.1:3000/"));
        for value in [
            "file:///tmp/private",
            "javascript:alert(1)",
            "https://user:pass@example.com/",
            "not-a-url",
        ] {
            assert!(!valid_browser_url(value), "{value}");
        }
        assert!(!valid_browser_url(&format!(
            "https://example.com/{}",
            "x".repeat(2_048)
        )));
    }

    #[test]
    fn screenshot_is_consumed_once_and_sent_as_image_content() {
        let temp = tempfile::tempdir().unwrap();
        let request_id = Uuid::new_v4().to_string();
        let file = temp.path().join(format!("{request_id}.png"));
        let png = b"\x89PNG\r\n\x1a\nfixture";
        std::fs::write(&file, png).unwrap();
        let image_url = staged_screenshot(temp.path(), &request_id, png.len() as u64).unwrap();
        assert!(!file.exists());
        let output = BrowserScreenshotOutput {
            image_url,
            tab_id: Uuid::nil().to_string(),
        };
        assert!(output.contains_external_context());
        let item = output.to_response_item(
            "call",
            &ToolPayload::Function {
                arguments: "{}".to_owned(),
            },
        );
        let ResponseInputItem::FunctionCallOutput {
            output: payload, ..
        } = item
        else {
            panic!("tool output is not a function result")
        };
        let FunctionCallOutputBody::ContentItems(items) = payload.body else {
            panic!("tool output has no content items")
        };
        assert!(matches!(
            items[1],
            FunctionCallOutputContentItem::InputImage { .. }
        ));
        assert!(
            serde_json::to_string(&items)
                .unwrap()
                .contains("data:image/png;base64,")
        );
        assert!(!output.log_output().contains("data:image"));
        assert!(staged_screenshot(temp.path(), &request_id, png.len() as u64).is_err());
    }
}
