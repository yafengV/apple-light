# 模型推理强度可见性

2026-09-26。当前 Codex Mac 的 Agent 页有“可用推理强度”控制，Max 和 Ultra 作为可选等级；模型选择器还根据模型能力限制可见选项。ShipiOS 现在在主窗口 Agent 页提供高级等级显示控制，模型选择器和独立模型配置页共用服务默认、无、最少、低、中、高、极高以及启用的 Max/Ultra 选项。旧工作区默认为不显示 Max/Ultra，设置可跨重启保存。

独立服务的标准 `/models` 响应未必包含能力信息。若服务额外返回 `supported_reasoning_efforts` 或 `supportedReasoningEfforts`，ShipiOS 会读取字符串列表或带 `reasoning_effort` / `reasoningEffort` 的对象列表，按当前模型过滤推理强度；没有该字段时保持手动可见性设置，并提示实际可用性由模型决定。已经选中的等级即使后来被隐藏也保留可见，直到用户主动更改。

39 项相关 Swift 测试通过，包括旧工作区迁移、持久化、可见顺序、两种模型能力格式、缺少能力数据与设置搜索。当前桌面锁屏，尚未与 Codex 的菜单、滑杆、焦点和键盘交互进行原生配对；Ultra 滑杆也尚未实现。
