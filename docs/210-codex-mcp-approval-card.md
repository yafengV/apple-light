# Codex MCP 专用审批卡

2026-09-26。Codex Responses 的 MCP 工具审批现使用固定版 Core 默认的 `elicitation_request` 事件。调用会先在任务时间线出现工具卡，审批时同一张卡显示参数、拒绝、本次允许和本任务允许；决定通过私有 Agent RPC 返回 Core。拒绝会保留已拒绝状态，工具不执行。本任务允许由 Core 的 session 授权处理，同一任务后续相同工具调用不再重复提问。

本地模型和 MCP 假服务的集成测试覆盖审批前不执行、本任务允许后的第二次调用、拒绝后不执行，以及工具卡与结果记录。MCP 表单请求已接入任务时间线，见[第 211 篇](211-codex-mcp-form-elicitation.md)；URL 与设备验证仍需处理。当前 Mac 锁屏，未完成与 Codex Mac 审批卡的视觉、焦点、键盘和辅助功能配对，因此完整 UI 验收数不变。
