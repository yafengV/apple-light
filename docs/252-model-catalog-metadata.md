# 模型目录元数据展示

2026-09-26。Codex Core 的模型预设含展示名称、说明和默认推理等级。ShipiOS 之前只显示原始模型 ID。当前从用户配置的独立 API 服务 `/models` 中读取可选的 `display_name` / `displayName` / `name`、`description` 和 `default_reasoning_level` / `default_reasoning_effort` / `defaultReasoningEffort`，在完整模型列表中显示名称与说明，并保留模型 ID。搜索同时匹配 ID、名称和说明；服务未提供元数据时仍按原始 ID 展示。服务默认等级有声明时，滑杆和当前等级标签会显示其含义，但发送请求仍保留原有“服务默认”的不显式指定语义。

模型选择相关 11 项测试覆盖目录解码、搜索、默认标签所需元数据和异步切换服务时不混用旧目录；构建、签名校验另行完成。Mac 当前锁屏，无法把代码及测试结果升级为 Codex 与 ShipiOS 的实际页面和交互一致验收。跨模型版本预设和完整视觉/键盘配对仍未完成。
