# Codex 文字任务跨重启续接

2026-09-26。Agent 为每个项目和任务保留独立 Codex home，并在其中原子保存 `thread.json`，只记录线程 ID 和私有 rollout 路径。重新进入同一项目、继续同一任务时，Agent 校验 rollout 仍位于该任务的私有目录，调用固定上游版本的 `ThreadManager::resume_thread_from_rollout`，并核对恢复后的线程 ID。密钥仍由 Swift 从 ShipiOS Keychain 读取，通过私有 stdio 注入本次 Agent 进程；线程记录不含密钥。

`codex.thread.start` 的响应新增 `resumed`。Swift 首次创建线程时发送当前可用文字上下文；恢复已有线程时只发送本轮新输入，避免历史重复进入模型。48 KiB 的启动上下文上限只适用于新线程，单轮输入仍受独立上限约束。缺失或无效的已登记 rollout 会报错，不会悄悄开一个丢失历史的新线程。旧版本没有线程记录的任务仍按首次会话启动。

本地假 Responses 服务的 Rust 测试覆盖停用 Agent 桥后重建、相同线程 ID、第二轮回复、任务归属和不落盘的 Bearer 密钥；超限的首次启动被拒绝，而恢复线程可通过同样大小的历史上下文。Swift 集成测试覆盖停止工作区、重建 Store、重新打开项目和继续旧任务；Agent 全部 7 项测试、相关 Swift 49 项测试、`script/build_and_run.sh --build-app` 与签名检查通过。

这是**已完成回合后的线程续接**。运行中回合在应用退出后的事件重放、工具审批、自主写入和 Codex 全页面配对仍未完成。Mac 当前锁屏，新增的重启交互尚未在原生可见页面逐项验收。
