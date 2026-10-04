# 原生 Hook 信任、生命周期与 Agent RPC

接续[核心矩阵](599-core-function-parity-matrix.md) C21。此前应用仅读取插件声明；此阶段补齐嵌入 Core 的执行与查询接口，尚未连接 Swift 设置页或应用会话的插件来源。不能将后端验证算为 Hooks 页面完整对齐。

## 已实现行为

- `SessionOptions.hooks` 接受明确的宿主来源、配置和逐处理器启用/信任状态。`codex.thread.start` 传入这些定义，`codex.hooks.list` 返回 Core 的当前哈希、信任状态、实际超时、异步标记和上下文限制。
- 定义作为内存中的私有用户配置层加入当前任务，保留现有 requirements。不会读取个人或项目的 Codex 配置，也不使用 managed 来源或信任绕过。来源 ID、状态键、配置大小和信任哈希均校验。
- 当前哈希和是否可执行由固定版本 Core 判定。命令、事件、匹配及 MCP 参数变更会使旧信任失效；单独停用保留其信任，其他处理器不受影响。
- 查询附带单个处理器的完整已验证定义，包括 MCP 输入和平台命令；摘要中的服务器/工具名称不能代替审阅参数。查询不执行命令，不创建配置文件。
- 文本生成用途主动移除 Hooks，避免 Git 文字生成等辅助请求继承任务扩展。
- `script/build_and_run.sh` 尊重 `CARGO_TARGET_DIR`，在独立 Rust 缓存构建时将同一缓存中的 Agent 捆绑到原生应用。

实现遵循官方[Hooks](https://learn.chatgpt.com/docs/hooks)及[插件打包](https://developers.openai.com/plugins/build/plugins)的逐定义信任要求。用户启用插件不等于信任 Hook。

## 实际验证

| 证据 | 范围及结果 |
| --- | --- |
| `.cache/native-hooks-workspace-tests.log` | Rust 工作区 **163 项通过**：vendored sandboxing 106 项、ShipiOS 57 项；包括 3 项 Hook 库用例及 1 项实际 Agent stdio 用例 |
| `.cache/native-hooks-clippy.log` | workspace/all-targets Clippy `-D warnings` 通过；fmt 检查通过 |
| `.cache/native-hooks-ipc-tests.log` | 实际 Agent 查询未信任→信任→定义修改→停用；完整元数据、无效来源/额外绕过字段拒绝、后续空查询恢复、项目配置未导入、命令未执行 |
| `.cache/native-hooks-lifecycle-example.log` | `hooks_mock` 使用真实 Core、实际 shell 命令和本机 Responses 夹具，四次请求通过：未信任无执行；信任后 SessionStart/UserPromptSubmit/Stop/SessionEnd 按生命周期运行；真实事件 JSON 进入命令，stdout 上下文进入 HTTP 请求；修改定义后仅该处理器跳过；辅助文字生成不执行 Hook |
| `.cache/native-hooks-app-run.log`、`.cache/native-hooks-signature.log` | 经项目脚本正式构建/启动及严格签名校验通过；前台工具确认 Mac 仍锁定，未确认可交互工作区 |

受外层沙箱限制，首次工作区运行的 4 项 Seatbelt 用例不能启动自身沙箱，生命周期夹具也不能绑定回环端口；在允许的沙箱外本机验证后通过。没有调用外部 API 或使用用户密钥。已有上游 linker/依赖 warning 保留，不将其描述为新增编译错误。

## 仍需完成

Swift 插件来源传递、设置页逐项审阅/信任/停用/重启保存、活动会话配置更新及执行审计尚未实现。此阶段采用宿主用户配置层，未提供原生插件来源分类和 `PLUGIN_ROOT`/`PLUGIN_DATA` 环境绑定；包含这些变量的插件不能据此宣称可运行。Agent stdio 的 64 KiB 帧上限仍在，较大定义需要附件传递，不能以库的 256 KiB 单来源上限推断 UI 可发送。

PreToolUse/PermissionRequest/PostToolUse、Compact、Interrupt、子代理、MCP 实际执行以及异步/超时/错误隔离仍需本项目真实闭环测试。Core 有这些实现不等于 ShipiOS 已完成验证。完整双端配对保持 **0/47**。

## 全量回归终态

旧提交 `f96b997` 的 `.cache/full-core-parity-regression.log` 已于 2026-10-05 结束，退出 1。Swift 运行 **2,569 项、3 项跳过、8 个失败用例产生 9 个失败断言**，总耗时 4,522 秒。涉及 ActivityArchiveTransport、ProjectlessConversation、TaskSearch、TerminalRestart（4 个用例）和 WorkspaceAttachedFile；归档已由第 602/603 篇专项接续，其余需定位。set-e 在 Swift 失败后未执行脚本末尾 IPC 冒烟。不得继续将该进程描述为运行中，也不得将局部回归算为全量通过。
