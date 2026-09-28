# Responses 提交说明与 PR 内容生成

## 参考与问题

2026-09-29 核对当前安装的公开应用资源，版本 `26.911.61220`、构建 `9647`，`git-action-new-branch-field-d7fd686030a3.js` 与既有副本逐字节相同。参考调用通过独立 `generate-commit-message`、`generate-commit-pull-request-message` 和 PR 生成流程处理 Git 内容，包含取消信号、手填字段保留、生成结果校验和错误提示。联合生成在提交说明、标题和描述都已填写时直接使用输入，否则按缺失字段生成。

ShipiOS 的普通会话已能选择 Codex Core · Responses，但提交说明和 PR 联合生成仍硬编码 `chat/completions`。只支持 Responses 的独立服务因此无法使用这些现有按钮。本阶段修复生成入口的协议路由，保留既有表单和 Git 工作流。

## 实现

`GitTextGenerator` 按当前独立配置选择 Chat Completions 或 Core Responses。提交说明按钮、空说明的自动提交，以及 PR 的标题、描述和联合提交说明生成共用该路由。服务、模型、推理等级和用户保存的 Git 指令随生成快照传递，不读取个人 Codex 配置或凭据。

Responses 使用独立临时 Agent 和 Core 线程，不复用用户正在运行的聊天、线程或历史。启动参数 `textOnly` 默认关闭，普通会话保持原配置；生成模式只接受新身份，拒绝续接和分叉。Core 强制只读权限、禁止工作区网络，不提供环境、MCP、浏览器或网页搜索，并通过启动时的空 `AllowedTools` 限制同时阻止工具广告和执行。项目指令、技能与环境提示不进入生成请求。

模型接收固定的 Git 内容快照与生成指令。大上下文经既有私有文本暂存通道传输，避开普通启动文字的 48 KiB 限制，暂存限制为 1 MB；生成结果限制为 128 KiB，提交说明和 PR 仍应用更严格的各字段校验。只有正常完整结束且非空的结果才进入表单，错误、取消和无效 PR JSON 不继续 Git 写入。

生成有 180 秒超时。取消、超时和正常结束共用同一次异步进程关闭，待关闭结束后移除临时会话、暂存及运行数据。原有手填内容、索引/分支变更检查、推送授权、失败续推及第 378 篇的弹层重置规则继续生效。

## 验证

Rust 工作区 144 项测试通过，零失败、无跳过，日志 `.cache/git-responses-rust-tests.log`。包括 106 项沙箱依赖测试、11 项 Agent 单元、2 项文件搜索、2 项 IPC 集成、11 项 Core 适配、3 项基础协议与 9 项工具测试。`cargo fmt --all -- --check` 和 `cargo clippy --locked --workspace --all-targets -- -D warnings` 通过，后者日志 `.cache/git-responses-clippy.log`。新 Agent 构建日志 `.cache/git-responses-agent-build.log`。

首组 12 项 Responses 定向集成测试通过，日志 `.cache/git-responses-focused-tests.log`。随后增加超时、部分文字后取消和浏览器预填串联测试，最终 53 项 Swift 相关回归全部通过，零失败、无跳过，耗时 657.455 秒，日志 `.cache/git-responses-regression.log`。包含 11 项提交说明、25 项既有 PR 与两种协议、11 项生成相关串联流程、6 项独立 Core 生成。首组 12 项包含在最终 53 项内，不重复相加。

已验证实际 `/v1/responses` 请求中的模型、推理等级、保存的生成指令和超过 48 KiB 的完整上下文；工具目录为空，主动返回未广告的命令调用也不能创建文件。取消、空/错误响应及测试中缩短为三秒的超时均清理临时历史。一个普通 Core 聊天在生成前后仍可继续，保留自己的工具目录。手填/索引变化和部分响应取消不替换草稿；联合生成使用真实 Git 提交与本地推送，直接创建按第 378 篇重置表单，浏览器路径保留预填并不虚构 PR。

`script/build_and_run.sh --build-app` 构建正式原生 macOS 应用包通过，Swift 构建耗时 32.40 秒；严格深度签名校验通过。日志 `.cache/git-responses-app-build.log`、`.cache/git-responses-signature.log`。仅构建，没有启动新应用或确认原生工作区可交互。

新增测试使用只监听 loopback 的 Responses 专用服务、实际 `shipios-agent`/Core、临时 Git 仓库及既有 GitHub CLI/推送夹具。不读取真实模型凭据、不访问收费模型服务、不创建真实 GitHub PR，也不打开用户浏览器。

## 仍待完成

默认分支/分离 HEAD 新分支入口、跨仓库 PR、合并监控及其余 UI 差异继续待开发。用户实际独立服务、生成按钮的原生点击/焦点/取消行为及当前 Codex 双端配对仍待验收。本阶段不以自动化测试或构建代替原生工作区可交互证据，完整配对保持 0/45。
