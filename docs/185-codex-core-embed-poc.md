# Codex Core 嵌入与配置隔离 PoC

2026-09-26。此验证使用 `upstream/codex.lock.json` 固定的 `50d77959bf927293c4b5ddcca81d05331ae582ea`，不读取或修改用户的 Codex 配置、认证与会话。

## 已验证的边界

- 在上游原工作区对 `codex-core-api` 执行 `cargo check --locked -p codex-core-api` 成功。
- `experiments/codex-core-embed` 作为独立 Rust host 引用固定源码的 `codex-core-api` 和 `codex-extension-api`，创建两个不同 `codex_home` 的 `Config`。两个目录中均放入无效 `config.toml`；显式独立配置加载仍成功，且仅 ShipiOS 实例接收其模型覆盖值。
- host 创建扩展注册表，注册一个 `ContextContributor`，并验证注册数量。此 contributor 尚未向模型会话提供上下文。
- 进一步构造 `ThreadManager`，在临时 ShipiOS 目录启动并关闭真实空线程；验证 `session_configured` 身份和预定 rollout 路径，详见[线程启动验证](187-codex-thread-bootstrap.md)。
- 用本地临时模型服务驱动文字回合，核对回复事件、完成事件、请求与 rollout 文件，详见[本地回合验证](188-codex-local-model-turn.md)。

使用 `./script/check_codex_core_embed.sh` 重跑。脚本先审计上游 revision 和工作树，再将上游锁文件复制到被忽略的 PoC 锁文件，最后编译运行。首次运行需要下载大量 Rust 依赖。上游使用三个 crate fork 补丁；单独的 host 不继承依赖工作区补丁，因此 PoC 清单显式保留相同补丁。重新解析不带上游锁文件的依赖曾选择不兼容的 `rama` 组合，不能把这种编译结果当作固定版本验证。

## 尚未验证

PoC 证明公开 API 可以在独立 host 中编译、隔离加载配置、启动线程并完成本地假服务回合。产品 `shipios-agent` 仍未链接 Codex Core，也没有接入实际用户模型服务、恢复会话、注册 iOS 工具、处理增量事件、取消、审批、沙箱、Skills/MCP 或产品会话持久化。`CODEX_HOME` 之外的系统管理策略和子进程环境仍需分别验证；不能据此称已实现完整运行时隔离或 Codex UI 对齐。

下一阶段应验证增量事件、错误与取消，再将线程生命周期接入 `shipios-agent`，随后引入结构化工具与审批。计划模式的结构化提问应接入真实会话事件，而不是仅在现有独立 API 会话中伪造同名工具。
