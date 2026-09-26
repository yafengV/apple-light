# 独立 Codex 线程启动验证

2026-09-26。在[固定版本嵌入 PoC](185-codex-core-embed-poc.md)的基础上，用公开 `codex-core-api` 实际构造 `ThreadManager`，创建并关闭一个线程。本篇记录先行的空线程验证；脚本随后扩展为[本地假服务回合验证](188-codex-local-model-turn.md)。空线程阶段没有提交模型回合，也没有使用用户的 API 凭据。

PoC 显式把 `codex_home`、认证文件存储、当前目录、工作区根目录和只读权限约束到临时 ShipiOS 目录；另一个临时 Codex home 只保留预置的无效配置文件。线程返回的 `session_configured.thread_id` 与创建的线程一致，rollout 的预定路径位于 ShipiOS home 下，关闭线程后另一个 home 未新增文件。空线程不生成 rollout 文件，因此本阶段不能证明会话持久化或恢复。

启动本地环境还需要执行服务器路径。第一次只向 `EnvironmentManager` 传 `None` 时得到 `local environment requires configured runtime paths`；按上游 sample 使用 `arg0_dispatch_or_else` 和 `ExecServerRuntimePaths` 后启动成功。这是产品集成的实际依赖，不应在后续打包时遗漏。

产品 `shipios-agent` 尚未链接这一 PoC。后续本地假服务已验证基本回合事件和持久文件；增量事件、工具注册和调用、审批、取消、恢复以及用户独立 API 服务的认证与模型协议仍未验证，UI 不能据此标为对齐。
