# Codex Core 嵌入与配置隔离 PoC

2026-09-26。此验证使用 `upstream/codex.lock.json` 固定的 `50d77959bf927293c4b5ddcca81d05331ae582ea`，不读取或修改用户的 Codex 配置、认证与会话。

## 已验证的边界

- 在上游原工作区对 `codex-core-api` 执行 `cargo check --locked -p codex-core-api` 成功。
- `experiments/codex-core-embed` 作为独立 Rust host 引用固定源码的 `codex-core-api` 和 `codex-extension-api`，创建两个不同 `codex_home` 的 `Config`。两个目录中均放入无效 `config.toml`；显式独立配置加载仍成功，且仅 ShipiOS 实例接收其模型覆盖值。
- host 创建扩展注册表，注册一个 `ContextContributor`，并验证注册数量。此 contributor 尚未向模型会话提供上下文。

使用 `./script/check_codex_core_embed.sh` 重跑。脚本先审计上游 revision 和工作树，再将上游锁文件复制到被忽略的 PoC 锁文件，最后编译运行。首次运行需要下载大量 Rust 依赖。上游使用三个 crate fork 补丁；单独的 host 不继承依赖工作区补丁，因此 PoC 清单显式保留相同补丁。重新解析不带上游锁文件的依赖曾选择不兼容的 `rama` 组合，不能把这种编译结果当作固定版本验证。

## 尚未验证

PoC 只证明公开 API 可以在独立 host 中编译，并验证了一种不读取配置文件的初始化路径。产品 `shipios-agent` 仍未链接 Codex Core，也没有创建/恢复真实 ThreadManager、注册 iOS 工具、流式事件、取消、审批、沙箱、认证、Skills/MCP 或会话持久化。`CODEX_HOME` 之外的系统管理策略和子进程环境仍需分别验证；不能据此称已实现完整运行时隔离或 Codex UI 对齐。

下一阶段应在 `shipios-agent` 的适配边界构建真实线程并用受控测试服务验证事件及取消，再引入结构化工具与审批。计划模式的结构化提问应接入真实会话事件，而不是仅在现有独立 API 会话中伪造同名工具。
