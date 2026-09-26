# Codex Core Agent RPC 通道

2026-09-26。`shipios-agent` 现在链接 `shipios-codex`，为每个 UUID 任务建立独立的 `Data/Codex/Tasks/<taskId>` 目录和 Codex 线程。JSON-RPC 增加 `codex.thread.start`、`codex.turn.submit`、`codex.turn.interrupt`、`codex.thread.stop`；上游事件以 `codex.event` 通知发送，参数包含 `taskId`、`threadId` 和原始事件。启动参数是 Responses 基础地址、模型及可选密钥；密钥只通过私有 stdio 请求传入，不写入运行记录。线程关闭时清除进程内认证。Agent 只分派 Codex exec/fs helper 模式，不运行上游会读取个人 `~/.codex/.env` 的完整 arg0 包装器。Swift 启动 Agent 时将 `CODEX_HOME` 指向 ShipiOS 数据目录。

本地假 Responses 服务测试覆盖任务线程启动、错误文本拒绝、唯一任务归属、真实回合事件、回复、关闭、Bearer 请求头和无 `auth.json`。打包后的 Agent 还通过 `python3 script/smoke_codex_rpc.py` 完成了完整 stdio RPC 回合，并验证独立 `CODEX_HOME`、事件归属及密钥不落盘。Swift 常用的大写 UUID 在对外事件与响应中保持原样，仅内部目录/索引规范化。Agent 全部 7 项单元/集成测试、Swift `AgentTests` 4 项测试、`script/build_and_run.sh --build-app`、包签名验证与 `script/smoke_ipc.py` 均通过。调试 Agent 链入上游后约 475 MB；Cargo 子进程文件搜索测试冷启动超过原 5 秒上限，因此测试等待上限改为 30 秒，独立探针与完整 Agent 回归均通过。

这是后端运行通道，**不是 UI 完全对齐验收**。Swift `AgentClient` 已识别 `codex.event` 与独立的事件缺口，但工作区聊天仍调用 Chat Completions。现有用户服务可能不支持 Responses；接入 UI 时须提供明确能力检查和选择，不能默默替换已配置的服务。多回合恢复、事件重放、工具审批、结构化提问、写入权限、跨进程锁和真实服务凭据链路仍待实现与验证。Mac 锁屏，原生交互未能在本轮复验。
