# Swift 文字会话接入 Codex Responses

2026-09-26。主窗口内的“模型与 API”设置新增明确的会话协议选择：原有 Chat Completions 与 Codex Core · Responses。旧 `model.json` 缺少协议字段时继续使用 Chat Completions；旧任务的模型选择也固定在原协议，避免修改全局设置后悄悄改变既有会话。用户选择 Responses 后，已连接项目的普通文字会话通过私有 Agent RPC 创建按任务隔离的 Codex 线程，同一任务后续消息复用线程。Swift 接收 `codex.event` 的增量、完整回复、错误与完成事件，停止操作发出中断；项目切换或 Agent 断线会结束等待中的 UI 回合。API Key 仍由 ShipiOS Keychain 按服务地址读取，再经私有 stdio 交给 Agent 的进程内认证。

当前 Responses 路径仅覆盖已连接项目的普通文字会话。图片、文件、代码审查、计划/目标模式和原有 MCP 工具在该路径上给出明确限制；项目外任务不可使用。Codex 线程仍为只读权限，写入工具和审批界面未接入。首次启动线程会把当前可用的文字上下文放入用户输入，超过 48 KiB 时提示新建任务；跨进程线程恢复和事件重放未实现。设置里的“测试连接”只检查 `/models`，首条消息才验证 `/responses`，因此不能把模型列表测试当作 Responses 兼容性证明。

本地假 Responses 服务的 Swift 工作区测试验证了新任务发送、回复落入当前任务、同一任务第二轮复用、全局协议变更后旧任务仍保持 Responses、以及中断时任务转为取消。旧配置迁移与现有 Chat Completions 回归共 49 项相关 Swift 测试通过；应用由 `script/build_and_run.sh --build-app` 构建。原生应用尚未在解锁桌面实际操作；与当前 Codex Mac 客户端的逐页视觉、焦点、键盘和拖放配对仍未完成。
