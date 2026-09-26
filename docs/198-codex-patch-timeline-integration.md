# Codex 原生补丁时间线集成验证

2026-09-26。ShipiOS 已把 Codex Core 的 `patch_apply_begin` 与 `patch_apply_end` 映射到聊天工具卡片，但此前只用合成事件测过时间线，没有证明真实模型工具回合会发出这些事件并写入项目。

本地假 Responses 服务现在发出原生 `apply_patch` 自定义工具调用。用固定版 Core 已识别的测试模型 `gpt-5.4` 时，Agent RPC 收到补丁开始和结束事件，隔离测试项目生成预期文件；Swift 集成测试也确认任务时间线保留成功的补丁卡片并持久化。这个测试只访问回环服务，不使用用户凭证。

测试曾用 `gpt-5.2` 强制发同样调用，Core 提示找不到该模型元数据，随后返回 `unsupported custom tool call: apply_patch`。这证明原生补丁可用性依赖所选模型在固定版 Core 中的工具元数据；不能据此声称任意自定义模型都有原生补丁工具。

当前工作区补丁无需额外批准，故本测试不覆盖 `apply_patch_approval_request` 的真实模型端到端流程。原生页面视觉、焦点与交互仍因桌面自动化接口超时未与当前 Codex Mac 逐项配对。
