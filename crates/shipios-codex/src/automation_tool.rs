//! A thread-scoped heartbeat control. The app owns persistence and acknowledges
//! the update before the model can claim that the schedule has been paused.
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
pub struct AutomationToolBridge {
    events: broadcast::Sender<Value>,
    pending: Pending,
}
impl AutomationToolBridge {
    pub fn new(events: broadcast::Sender<Value>) -> Self {
        Self {
            events,
            pending: Arc::new(Mutex::new(HashMap::new())),
        }
    }
    pub fn resolve(&self, task: &str, request: &str, result: Value) -> bool {
        let mut pending = self.pending.lock().expect("automation request lock");
        if pending.get(request).is_none_or(|(owner, _)| owner != task) {
            return false;
        }
        pending
            .remove(request)
            .is_some_and(|(_, reply)| reply.send(result).is_ok())
    }
    pub fn cancel_task(&self, task: &str) {
        self.pending
            .lock()
            .expect("automation request lock")
            .retain(|_, (owner, _)| owner != task);
    }
    async fn request(&self, task: &str, automation: &str, reason: &str) -> Result<Value, String> {
        let request = Uuid::new_v4().to_string();
        let (reply, receiver) = oneshot::channel();
        self.pending
            .lock()
            .expect("automation request lock")
            .insert(request.clone(), (task.to_owned(), reply));
        let _guard = PendingGuard {
            request: request.clone(),
            pending: Arc::clone(&self.pending),
        };
        self.events
            .send(json!({"taskId":task, "event": {
                "type":"automation_pause_request", "requestId":request,
                "automationId":automation, "reason":reason
            }}))
            .map_err(|_| "ShipiOS is not connected to pause this heartbeat.".to_owned())?;
        match tokio::time::timeout(Duration::from_secs(30), receiver).await {
            Ok(Ok(value)) => Ok(value),
            Ok(Err(_)) => Err("Heartbeat pause request was cancelled.".to_owned()),
            Err(_) => Err(
                "Heartbeat pause request timed out. Do not assume the schedule was paused."
                    .to_owned(),
            ),
        }
    }
}
struct PendingGuard {
    request: String,
    pending: Pending,
}
impl Drop for PendingGuard {
    fn drop(&mut self) {
        self.pending
            .lock()
            .expect("automation request lock")
            .remove(&self.request);
    }
}

pub struct AutomationToolContributor {
    bridge: AutomationToolBridge,
    task: String,
    automation: String,
}
impl AutomationToolContributor {
    pub fn new(bridge: AutomationToolBridge, task: String, automation: String) -> Self {
        Self {
            bridge,
            task,
            automation,
        }
    }
}
impl ToolContributor for AutomationToolContributor {
    fn tools(
        &self,
        _: &ExtensionData,
        _: &ExtensionData,
    ) -> Vec<Arc<dyn for<'call> ToolExecutor<ToolCall<'call>>>> {
        vec![Arc::new(PauseTool {
            bridge: self.bridge.clone(),
            task: self.task.clone(),
            automation: self.automation.clone(),
        })]
    }
}
struct PauseTool {
    bridge: AutomationToolBridge,
    task: String,
    automation: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PauseArgs {
    reason: String,
}
impl<'call> ToolExecutor<ToolCall<'call>> for PauseTool {
    fn tool_name(&self) -> ToolName {
        ToolName::plain("shipios_pause_automation")
    }
    fn spec(&self) -> ToolSpec {
        ToolSpec::Function(ResponsesApiTool {
            name: "shipios_pause_automation".to_owned(),
            description: "Pause only the PR heartbeat attached to this thread before your final response when it is complete or blocked by unavailable credentials, access or a user decision. Report the exact reason and ask one concise question in the thread if input is needed. This does not interrupt the current turn or create, resume or change any other automation.".to_owned(),
            strict: false,
            parameters: parse_tool_input_schema(&json!({"type":"object","properties":{
                "reason":{"type":"string","minLength":1,"maxLength":4096}
            },"required":["reason"],"additionalProperties":false})).expect("heartbeat pause schema"),
            output_schema: None, defer_loading: None,
        })
    }
    fn handle<'a>(&'a self, call: ToolCall<'call>) -> codex_extension_api::ToolExecutorFuture<'a>
    where
        'call: 'a,
    {
        Box::pin(async move {
            let args: PauseArgs = serde_json::from_str(call.function_arguments()?)
                .map_err(|error| FunctionCallError::RespondToModel(error.to_string()))?;
            let reason = args.reason.trim();
            if reason.is_empty() || reason.len() > 4096 || reason.contains('\0') {
                return Err(FunctionCallError::RespondToModel(
                    "Provide a nonempty reason within 4096 bytes.".to_owned(),
                ));
            }
            let result = self
                .bridge
                .request(&self.task, &self.automation, reason)
                .await
                .map_err(FunctionCallError::RespondToModel)?;
            Ok(Box::new(JsonToolOutput::new(result)) as Box<dyn ToolOutput>)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn host_acknowledgement_is_owned_and_single_use() {
        let (events, mut receiver) = broadcast::channel(4);
        let bridge = AutomationToolBridge::new(events);
        let caller = bridge.clone();
        let pending =
            tokio::spawn(
                async move { caller.request("task-a", "watch-a", "Missing access").await },
            );
        let event = receiver.recv().await.unwrap();
        assert_eq!(event["taskId"], "task-a");
        assert_eq!(event["event"]["automationId"], "watch-a");
        let id = event["event"]["requestId"].as_str().unwrap();
        assert!(!bridge.resolve("task-b", id, json!({"status":"paused"})));
        assert!(!pending.is_finished());
        assert!(bridge.resolve(
            "task-a",
            id,
            json!({"status":"error", "message":"Save failed"})
        ));
        assert_eq!(pending.await.unwrap().unwrap()["status"], "error");
        assert!(!bridge.resolve("task-a", id, json!({"status":"paused"})));
    }
    #[tokio::test]
    async fn cancelled_and_disconnected_calls_release_pending_requests() {
        let (events, mut receiver) = broadcast::channel(4);
        let bridge = AutomationToolBridge::new(events);
        let caller = bridge.clone();
        let pending =
            tokio::spawn(async move { caller.request("task-a", "watch-a", "Complete").await });
        receiver.recv().await.unwrap();
        bridge.cancel_task("task-a");
        assert!(pending.await.unwrap().is_err());
        assert!(bridge.pending.lock().unwrap().is_empty());
        let caller = bridge.clone();
        let pending =
            tokio::spawn(async move { caller.request("task-a", "watch-a", "Complete").await });
        receiver.recv().await.unwrap();
        pending.abort();
        let _ = pending.await;
        assert!(bridge.pending.lock().unwrap().is_empty());
        drop(receiver);
        assert!(
            bridge
                .request("task-a", "watch-a", "Complete")
                .await
                .is_err()
        );
        assert!(bridge.pending.lock().unwrap().is_empty());
    }
}
