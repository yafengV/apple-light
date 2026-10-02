use codex_extension_api::{
    ExtensionData, FunctionCallError, JsonToolOutput, ResponsesApiTool, ToolCall, ToolContributor,
    ToolExecutor, ToolName, ToolOutput, ToolSpec, parse_tool_input_schema,
};
use serde_json::{Value, json};
use std::sync::Arc;
use tokio::sync::broadcast;

pub struct ConfettiToolContributor {
    task_id: String,
    events: broadcast::Sender<Value>,
}

impl ConfettiToolContributor {
    pub fn new(task_id: String, events: broadcast::Sender<Value>) -> Self {
        Self { task_id, events }
    }
}

impl ToolContributor for ConfettiToolContributor {
    fn tools(
        &self,
        _session_store: &ExtensionData,
        _thread_store: &ExtensionData,
    ) -> Vec<Arc<dyn for<'call> ToolExecutor<ToolCall<'call>>>> {
        vec![Arc::new(ConfettiTool {
            task_id: self.task_id.clone(),
            events: self.events.clone(),
        })]
    }
}

struct ConfettiTool {
    task_id: String,
    events: broadcast::Sender<Value>,
}

fn emit_confetti(events: &broadcast::Sender<Value>, task_id: &str) -> Result<(), String> {
    events
        .send(json!({"taskId": task_id, "event": {"type": "confetti_fire"}}))
        .map(|_| ())
        .map_err(|_| "ShipiOS is not connected to show confetti.".to_owned())
}

impl<'call> ToolExecutor<ToolCall<'call>> for ConfettiTool {
    fn tool_name(&self) -> ToolName {
        ToolName::plain("shipios_fire_confetti")
    }

    fn spec(&self) -> ToolSpec {
        ToolSpec::Function(ResponsesApiTool {
            name: "shipios_fire_confetti".to_owned(),
            description: "Fire a short confetti celebration in ShipiOS only when the user asks for confetti or explicitly invites a celebration. Do not use this for routine task completion.".to_owned(),
            strict: false,
            parameters: parse_tool_input_schema(&json!({
                "type": "object", "properties": {}, "additionalProperties": false
            }))
            .expect("confetti schema"),
            output_schema: None,
            defer_loading: None,
        })
    }

    fn handle<'a>(&'a self, call: ToolCall<'call>) -> codex_extension_api::ToolExecutorFuture<'a>
    where
        'call: 'a,
    {
        Box::pin(async move {
            let arguments: Value = serde_json::from_str(call.function_arguments()?)
                .map_err(|error| FunctionCallError::RespondToModel(error.to_string()))?;
            if arguments.as_object().is_none_or(|value| !value.is_empty()) {
                return Err(FunctionCallError::RespondToModel(
                    "Confetti does not take arguments.".to_owned(),
                ));
            }
            emit_confetti(&self.events, &self.task_id)
                .map_err(FunctionCallError::RespondToModel)?;
            Ok(Box::new(JsonToolOutput::new(json!({"requested": true}))) as Box<dyn ToolOutput>)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn confetti_goes_to_the_owning_task_only_when_app_is_connected() {
        let (events, mut receiver) = broadcast::channel(4);
        emit_confetti(&events, "task-a").unwrap();
        let event = receiver.recv().await.unwrap();
        assert_eq!(event["taskId"], "task-a");
        assert_eq!(event["event"]["type"], "confetti_fire");
        drop(receiver);
        assert!(emit_confetti(&events, "task-a").is_err());
    }
}
