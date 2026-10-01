# 会话状态中的模型窗口用量与运行时说明

[OpenAI 官方设置说明](https://learn.chatgpt.com/docs/reference/settings)列出通用页的运行防休眠和追加消息行为。ShipiOS 的运行时页仍声称 Codex Core 自主编码工具未接入，与真实 Core 会话实现矛盾；现在按独立 API 的当前协议说明 Agent 已有的诊断、构建及 Codex Core 工具能力。

会话状态页原先即使模型目录提供 `context_window`，仍一律显示“无法计算使用百分比”。现在从当前独立服务与模型的已加载目录读取上限，仅在最近一轮用量记录的模型和输入 token 均与显示的最近上下文用量一致，且输入未超过窗口时，显示进度和百分比。切换模型或服务后不把旧轮次除以新模型的窗口。Chat Completions 任务没有 Codex 会话 ID 时标为“不适用”，Codex Core 任务尚未建立时仍显示“尚未建立”。没有目录上限时保持明确的未知状态；此实现不推测服务未返回的上限。

`TaskStatusCommandTests` 与 `ModelSelectionTests` 共 16 项通过，覆盖模型/服务隔离、用量匹配和缺失上限。`script/build_and_run.sh --build-app` 完成正式应用构建，严格深度签名检查通过。Mac 锁屏阻挡该版本的前台点击与视觉验收，Codex 参考应用的桌面控制接口也拒绝访问；这不是双端交互配对通过，完整清单仍为 **0/45**。
