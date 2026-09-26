# Codex Core 产品适配库

2026-09-26。`crates/shipios-codex` 已加入产品 Rust workspace，通过 Git revision `50d77959bf927293c4b5ddcca81d05331ae582ea` 固定 `codex-core-api`、`codex-extension-api` 与 `codex-login`。它从显式传入的 ShipiOS home、项目目录、模型、Responses 基础地址及可选密钥创建线程，暴露文字提交、线程事件、rollout 路径和关闭接口。当前仅允许只读权限；写入工具与审批界面尚未接入。

适配库校验 HTTPS 或本机 HTTP 地址，不从个人 Codex 配置或 `OPENAI_API_KEY` 读取凭据。密钥由调用方传入后进入 Codex 的进程内 ephemeral auth，生命周期结束时清除；并发会话不能共用同一 home。自定义 provider 明确关闭 WebSocket，避免对只支持 HTTP Responses 的服务发起错误探测。

`cargo run --locked -p shipios-codex --example local_mock` 使用本机假服务进行真实回合：验证回复先于完成事件、rollout 落在 ShipiOS home、请求带测试 Bearer 凭据，以及 `auth.json` 和 rollout 都不含凭据。同 home 并发启动被拒绝。运行该例需要允许绑定本机 loopback 端口。`cargo clippy --locked -p shipios-codex --all-targets -- -D warnings`、`cargo test --workspace --locked` 与 `script/build_and_run.sh --build-app` 均通过。

上游 `codex-state` 依赖 `libsqlite3-sys 0.37`，与原有 `rusqlite 0.38` 的 `libsqlite3-sys 0.36` 无法在同一工作区链接，因此将 ShipiOS 升至 `rusqlite 0.39`；现有 Rust 存储与全工作区测试通过。适配库尚未由 `shipios-agent` 的 RPC 调用，Swift UI 仍使用 Chat Completions。固定上游版本仅接受 Responses，用户已配置的独立服务是否兼容须在接入时明确验证；不能把此库编译通过描述为 UI 完全对齐。

本次在 Rust 1.97.1 上构建与测试通过；仓库声明的最低 Rust 1.95 尚未实机复测。原生页面与交互验收仍受 Mac 锁屏限制。

下一步是把线程生命周期和事件流接到 Agent RPC，提供按任务独立的运行目录及取消、错误、审批和结构化提问映射，再让 Swift 会话选择并使用该路径。并发跨进程目录锁、实际服务凭据传输与持续会话恢复也仍需验证。当前 Mac 锁定，尚无本轮原生交互验收。
