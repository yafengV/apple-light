//! A native Codex tool that asks the owning macOS app to inspect its WebKit tabs.
//! The Agent cannot read a browser page directly or bypass the app's site policy.

use codex_extension_api::{
    ExtensionData, FunctionCallError, JsonToolOutput, ResponsesApiTool, ToolCall, ToolContributor,
    ToolExecutor, ToolName, ToolOutput, ToolSpec, parse_tool_input_schema,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
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
}

impl BrowserToolBridge {
    pub fn new(events: broadcast::Sender<Value>) -> Self {
        Self {
            task_id: String::new(),
            events,
            pending: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub fn for_task(&self, task_id: String) -> Self {
        Self {
            task_id,
            events: self.events.clone(),
            pending: Arc::clone(&self.pending),
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
    ) -> Result<Value, String> {
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
                "handle": handle, "text": text}
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
            Ok(Ok(value)) => Ok(value),
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
            description: "Use the task's ShipiOS browser. list returns tab IDs; open navigates to an http/https URL; read returns visible page text; inspect returns live interactive element handles; click activates a handle; fill enters text in a text field. Inspect again after navigation or page changes. ShipiOS checks website access and may ask the user.".to_owned(),
            strict: false,
            parameters: parse_tool_input_schema(&json!({
                "type": "object",
                "properties": {
                    "action": {"type": "string", "enum": ["list", "read", "open", "inspect", "click", "fill"]},
                    "tab_id": {"type": "string", "description": "Required for read; use an ID returned by list."},
                    "url": {"type": "string", "description": "Required for open; absolute http/https URL."},
                    "handle": {"type": "string", "description": "Required for click and fill; use a handle returned by inspect."},
                    "text": {"type": "string", "description": "Required for fill; text to enter, at most 4000 characters."}
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
                "list" | "read" | "open" | "inspect" | "click" | "fill"
            ) || (matches!(args.action.as_str(), "read" | "inspect" | "click" | "fill")
                && args
                    .tab_id
                    .as_ref()
                    .is_none_or(|id| Uuid::parse_str(id).is_err()))
                || (args.action == "open"
                    && args
                        .url
                        .as_ref()
                        .is_none_or(|value| !valid_browser_url(value)))
                || (matches!(args.action.as_str(), "click" | "fill")
                    && args.handle.as_ref().is_none_or(|value| {
                        value.len() > 100 || !value.is_ascii() || !value.contains(':')
                    }))
                || (args.action == "fill"
                    && args
                        .text
                        .as_ref()
                        .is_none_or(|value| value.chars().count() > 4_000))
            {
                return Err(FunctionCallError::RespondToModel(
                    "Use list, open with an http/https URL, read or inspect with a tab_id, or click/fill with a tab_id and inspected handle (plus text for fill).".to_owned(),
                ));
            }
            let result = self
                .bridge
                .request(&args.action, args.tab_id, args.url, args.handle, args.text)
                .await
                .map_err(FunctionCallError::RespondToModel)?;
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
        let bridge = BrowserToolBridge::new(events);
        let task = bridge.for_task("task-a".to_owned());
        let pending =
            tokio::spawn(async move { task.request("list", None, None, None, None).await });
        let event = receiver.recv().await.expect("request event");
        let id = event["event"]["requestId"].as_str().unwrap();
        assert_eq!(event["taskId"], "task-a");
        assert!(!bridge.resolve("task-b", id, json!({"status":"ok"})));
        assert!(bridge.resolve("task-a", id, json!({"status":"ok"})));
        assert_eq!(pending.await.unwrap().unwrap()["status"], "ok");
        assert!(!bridge.resolve("task-a", id, json!({"status":"ok"})));
    }

    #[tokio::test]
    async fn stopping_a_task_cancels_its_pending_browser_request() {
        let (events, mut receiver) = broadcast::channel(8);
        let bridge = BrowserToolBridge::new(events);
        let task = bridge.for_task("task-a".to_owned());
        let pending = tokio::spawn(async move {
            task.request("read", Some(Uuid::new_v4().to_string()), None, None, None)
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
}
