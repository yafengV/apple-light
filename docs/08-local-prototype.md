# P0 本地原型：实现与验证

日期：2026-09-16。用户选择“先实现本地部分，稍后配置模型”。此次实现没有调用模型、创建凭据或读取个人 Codex 登录状态。

## 当前可用能力

Rust workspace 分成三个 crate：配置与持久化、iOS 工具、Agent 进程。可通过 CLI 或 stdio JSON-RPC 运行 `doctor` 和 `build`。

- 显式加载 ShipiOS 用户配置；项目 `.shipios/config.toml` 需传 `--trust-project-config`。来源优先级为运行参数 > 已信任项目 > 产品用户配置 > 默认值。
- 支持 `model`（仅保留配置、不调用）、`build_timeout_seconds`（1–3600，默认 300）、`developer_dir`。未知字段与含错误的配置拒绝加载，错误消息不回显配置内容。
- 数据目录可显式选择，默认与 `.codex` 分离；拒绝直接或符号链接解析到 `.codex` 的数据目录。SQLite 保存运行状态及有序事件，目录级实例锁阻止两个 Agent 同时操作。
- 项目扫描最多五层、10,000 个条目，跳过隐藏目录、依赖、构建缓存和符号链接，返回容器列表而不自动挑选 scheme。
- 构建要求显式 container 与 scheme；容器经 canonicalize 后必须在所选项目内。固定 iOS Simulator destination、禁用代码签名、将 DerivedData 与 xcresult 写入本次运行的工件目录。
- 子进程使用参数数组与清理后的环境。取消/超时终止所属进程组；stdout/stderr 各保存最多 4 MiB，响应保留头尾摘要与截断标志。
- SQLite 中运行和状态事件在事务内更新。重启将尚未终结的任务标为 `interrupted`，保留工件，**不自动重放构建或外部操作**。
- SwiftUI 桌面客户端已实现；详情见 [原生 macOS 验收记录](09-macos-validation.md)。Foundation 探针仍可独立验证通信。

## 源码核对结论

锁定版本：[50d77959bf927293c4b5ddcca81d05331ae582ea](https://github.com/openai/codex/tree/50d77959bf927293c4b5ddcca81d05331ae582ea)。缓存位于忽略的 `.cache/codex-upstream`，没有对上游源码打补丁。

| 确认项 | 入口 |
| --- | --- |
| `codex-core-api` 的 `ThreadManager`、`ExtensionRegistryBuilder` 导出 | `codex-rs/core-api/src/lib.rs` |
| `ToolContributor` 与 `ApprovalReviewContributor` | `codex-rs/ext/extension-api/src/contributors.rs` |
| 工具注册与 registry 构造 | `codex-rs/ext/extension-api/src/registry.rs` |
| 直接组装配置、建立线程的样例 | `codex-rs/thread-manager-sample/src/main.rs` |
| 配置层仍涉及系统、项目和管理来源 | `codex-rs/config/src/loader/README.md` |

`python3 script/audit_codex.py` 可按锁定版本复查这些符号。它是源码结构检查，**不是 Rust 编译或内嵌运行验证**。另外已在缓存源码执行 `cargo check -p codex-extension-api --locked`，该 crate 及其依赖编译通过（日志 `.cache/codex-extension-check.log`，约 8 分 46 秒）；这在本报告当时不等于 ShipiOS 已链接上游。此段是早期状态快照；当前产品已接入 Codex Agent RPC，见[第 190 篇](190-codex-agent-rpc.md)。

## 已运行的验证

环境：macOS、Homebrew Rust 1.97.1、Xcode 26.3（17C529）。

| 检查 | 结果 |
| --- | --- |
| `cargo fmt --all -- --check` | 通过 |
| `cargo clippy --workspace --all-targets --locked -- -D warnings` | 通过 |
| `cargo test --workspace --locked` | 12 项通过 |
| `python3 script/audit_codex.py` | 固定版本与源码符号检查通过 |
| `python3 script/smoke_ipc.py` | 真实诊断、事件重放、构建取消、重启后历史和帧大小限制通过 |
| `./script/verify_swift_ipc.sh` | Swift → Rust 握手、诊断及事件接收通过 |
| fixture 真实构建 | 正常 macOS 环境下退出码 0，约 5.4 秒；生成 App 与 xcresult |

真实成功构建的 run ID：`0d3aba82-7d6f-4c18-baf8-83a76b87b482`。本机工件位于 `.shipios-local/Artifacts/<run-id>/`，不会提交到 Git。首次受限执行环境中出现 Simulator 服务连接错误，进程未正常退出，系统正确记录失败；随后在正常环境完成成功构建。

Rust 测试覆盖配置优先级/信任、个人 Codex 哨兵配置不被使用、环境凭据不被输出、符号链接隔离、无效握手、不可逆终态、启动恢复、实例锁、扫描边界、非零退出码、进程组取消、超时、长日志和信号退出。未将测试哨兵视为真实凭据。

## 隔离范围与剩余限制

当前通过的是 **ShipiOS 自有配置/状态与工具环境** 的隔离测试。未接入 Codex Core，所以不能据此推断其认证、Keychain、Skills、MCP、插件、项目指令或 MDM 隔离已通过。

`HOME` 被保留以便 Xcode 正常运行，Xcode 可读取系统开发者设置和签名环境。构建阶段本身可执行项目代码；当前没有额外 OS 沙箱、worktree 或源码树证据绑定。构建前应选择信任的项目；成功结果始终包含 `verification: not_run`。

正常取消、EOF、SIGINT 和 SIGTERM 会请求停止任务。SIGKILL、系统断电等无法执行清理的情况只在重启后标记 `interrupted`；还没有孤儿构建进程回收或自动续跑机制。恢复历史不等于恢复正在执行的任务。

工件是本地原始构建日志，可能含工程自己的敏感输出；不上传、不发送模型，也未实现通用秘密识别或脱敏。桌面端支持受限日志读取和报告导出；自动清理、配额及正式发布分发仍待完成。

## P0 进度

| 任务 | 状态 |
| --- | --- |
| P0-01 上游版本与接口审计 | 已固定版本、核对关键入口；产品依赖编译与分发清单未完成 |
| P0-02 内嵌 AgentRuntime | 未实现；当前为本地任务执行进程 |
| P0-03 Codex 工具扩展 | 接口已确认，尚未编译注册工具 |
| P0-04 配置/认证隔离 | 自有配置通过；Codex 与认证部分待接入 |
| P0-05 Skills/MCP/发现审计 | 尚未运行验证 |
| P0-06 Xcode/UI 驱动 | 真实构建通过；安装、启动、操作和断言待实现 |
| P0-07 IPC/生命周期 | 本地协议、SwiftUI 客户端、取消/退出清理、断线重连和历史恢复已验证；Codex 事件映射待接入 |
| P0-08 技术决策收敛 | 尚未完成 |

下一阶段优先在固定版本建立 `shipios-codex` 适配 PoC，先验证不调用模型的配置构造和工具注册，再在独立认证决策后接入真实会话。保留内嵌路线，不引入对用户个人 Codex CLI 的运行依赖。
