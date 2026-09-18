# MCP 连接状态与工具发现

2026-09-18。接续 MCP 配置页，让连接按钮、停用、重连、错误状态和工具列表使用真实服务响应。

## 依据

协议参考 MCP 官方的 [传输规范](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)、[初始化生命周期](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle) 和 [工具发现](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)。支持的协商版本为 2025-11-25、2025-06-18 和 2025-03-26。

UI 继续参考 Codex 本地 `plugins-page-8862e0071989.js` 中逐服务器设置、启停和授权状态入口。OAuth 注册与授权按钮尚未实现，因此不展示不可执行的授权按钮。

## 行为

- 列表按真实状态显示未连接、连接中、已连接及工具数量、失败、已停用；可连接、取消、断开及重试。
- STDIO 启动配置中的命令与独立参数，经换行分隔的 JSON-RPC 完成握手。环境仅包含基础变量、显式透传变量及本服务器配置，不自动继承个人 Codex 环境。协议输出与诊断输出分开读取。
- HTTP 使用独立临时 URLSession，支持 JSON 与 SSE 响应、会话标识和协商版本请求头；拒绝自动重定向，以免把配置凭据发送到另一地址。支持配置中的直接请求头与环境变量凭据。
- 完成初始化后发出 initialized 通知，再分页读取工具。重复名称、循环分页、无效参数定义、不支持的协议和异常响应均进入错误状态。
- 工具弹层支持名称/描述搜索、展开参数 schema、手动刷新、关闭；STDIO 的工具变更通知触发刷新。服务端 ping 请求可应答，未声明的客户端能力明确返回不支持。
- 停用或编辑保存会断开连接；重新启用会连接。新建配置和应用恢复仅加载配置，首次连接由列表按钮触发。重连等待旧连接关闭，取消后的旧结果不能回写新状态。
- 应用退出等待连接清理。STDIO 先关闭输入，再在限定时间后终止仍存活的子进程；HTTP 尝试删除已建立的会话。

## 验证与边界

新增本地 Python MCP 测试服务，覆盖分段 STDIO 消息、HTTP JSON/SSE、初始化顺序、会话与版本请求头、ping、分页、刷新、环境隔离、子进程退出、超时、无效消息、授权失败、重定向拒绝和重复工具。

连接与配置初次共 11 项测试通过，日志 `.cache/mcp-connection-tests.log`。随后改进重连等待与刷新进度，86 项相邻功能回归通过，记录在 `.cache/mcp-connection-regression.log`。收尾禁止配置重载及退出期间启动新连接，再通过 11 项 MCP 回归，记录在 `.cache/mcp-connection-final-tests.log`。

仍未实现会话中的工具调用、逐工具权限/审批、OAuth、插件内 MCP 逐项运行、HTTP 后台通知订阅、断流事件重放及旧版 HTTP+SSE 兼容。HTTP 会话失效显示失败，可手动重新连接。工具弹层明确说明调用尚未接入。

CUA 本轮继续报告 Mac 锁屏，新增控件的可见布局、弹层和焦点尚未完成原生验收。以上连接测试不能证明全部 UI 或 MCP 功能完全对齐。

应用构建及严格深度签名检查通过，日志 `.cache/mcp-connection-build.log`。已重新启动原 `.shipios-local/desktop` 实例，受保护任务及草稿保留。

后续已接入 [会话工具调用和任务内审批](90-mcp-tool-calls-and-approval.md)，先前“调用尚未接入”的提示已替换。完整权限设置、OAuth、富内容结果等差异仍保留。
