# Codex Responses MCP 工具接入

2026-09-26。ShipiOS 的独立 MCP 设置现在随 Codex Responses 任务启动交给隔离的 Codex Core。已启用的 STDIO 和 Streamable HTTP 服务可经 Core 的 `tool_search` 被模型发现并调用；工具开始、结束和结果进入任务时间线。关闭或修改服务后，同一任务的下一回合重连线程并恢复原会话历史，新的服务列表立即生效。

未标注为只读的工具会先在任务时间线展示 Codex 审批问题，收到允许回答后才执行。ShipiOS 暂将 Core 的 MCP 审批路由到已支持的结构化提问通道。配置仍属于 ShipiOS 私有数据目录，不读取用户个人 Codex 配置。独立本地模型和 MCP 假服务的集成测试覆盖 STDIO 调用、HTTP 调用、审批前不执行、审批后恢复、结果时间线记录和同任务禁用生效。

这些是代码与自动化证据。当前锁屏环境未完成 ShipiOS 与 Codex Mac 的页面、布局、焦点、键盘和真实服务逐项配对，因此 43 类完整 UI 验收数仍为 0。
