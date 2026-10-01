# 应用私有命名权限配置：Agent 预置与校验

本阶段让 ShipiOS 能把应用提供的命名权限 TOML 写入任务专属 Codex home，并在启动真实 Core 会话前用同一 Core 配置加载器校验。协议新增 `permissionProfileConfig`，以及用于明确清除旧选择的 `permissionProfileSelectionExplicit`。旧请求仍按原有持久化选择恢复；分叉在没有新配置时复制来源任务的私有配置。

校验入口 `shipios-agent --project <目录> validate-permission-profile --id <名称> --config-path <文件>` 只接受权限相关顶层键，不允许借配置文档覆盖模型、认证、MCP 等应用独立设置。配置最大 64 KiB，ID 限制为 1–64 个字母、数字、点、连字符或下划线。写入时使用 0600 临时文件和原子替换，拒绝把已有符号链接当成任务配置。切回内置权限时不加载留在任务目录的命名配置。

验证：`shipios-codex` 14 项测试、`shipios-agent` 15 项测试、Rust fmt/Clippy 均通过；Agent 两项回环 mock 测试需本机端口权限。`script/build_and_run.sh --build-app` 完成正式包构建，包内 Agent 对合法只读配置返回 `valid`，严格深度签名通过。本阶段没有启动或操作原生窗口；因此没有新增可交互工作区或 Codex 双端页面验收证据。

应用设置尚未提供命名权限档案的创建、编辑和输入区选择，Swift 客户端也尚未发送新协议字段；当前改动是下一阶段 UI 接线所需的运行路径。45 个页面/交互验收面仍为 **0/45** 完整双端配对，不能据此宣称 UI 已对齐。
