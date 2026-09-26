# Codex Responses MCP 工具接入

2026-09-26。ShipiOS 的独立 MCP 设置现在随 Codex Responses 任务启动交给隔离的 Codex Core。已启用的 STDIO 和 Streamable HTTP 服务可经 Core 的 `tool_search` 被模型发现并调用；工具开始、结束和结果进入任务时间线。关闭或修改服务后，同一任务的下一回合重连线程并恢复原会话历史，新的服务列表立即生效。

未标注为只读的工具先经过审批，收到允许后才执行。审批已从最初的结构化提问通道改为 Core 默认的专用 elicitation 事件，并在工具卡中处理，见[第 210 篇](210-codex-mcp-approval-card.md)。配置仍属于 ShipiOS 私有数据目录，不读取用户个人 Codex 配置。独立本地模型和 MCP 假服务的集成测试覆盖 STDIO 调用、HTTP 调用、审批前不执行、审批后恢复、结果时间线记录和同任务禁用生效。

这些是代码与自动化证据。当前锁屏环境未完成 ShipiOS 与 Codex Mac 的页面、布局、焦点、键盘和真实服务逐项配对，因此 43 类完整 UI 验收数仍为 0。
