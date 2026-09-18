# ShipiOS local IPC v1

启动：`shipios-agent --project <path> --data-dir <path> serve`。一进程对应一个选定项目与数据目录；同一数据目录只允许一个实例。

传输为 stdin/stdout 上每行一条 UTF-8 JSON-RPC 2.0 消息。日志写 stderr。最大输入帧 64 KiB（含换行），超限返回错误并关闭连接。暂不支持 batch、socket、多客户端或热切换项目。

## 握手

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}
```

返回 `protocolVersion`、`serverVersion`、项目、数据目录和能力。当前 `runKinds` 为 `doctor`、`build`；`modelCalls`、`codexEmbedded`、`uiVerification` 和 `release` 都为 false。版本不兼容时不初始化，客户端可再次握手。

所有方法必须有字符串或整数 `id`。无 ID 的 notification 不执行方法，也不回复。握手后无需额外发送 `initialized`。

## 方法

| 方法 | params | 返回 |
| --- | --- | --- |
| `config.get` | `{}` | 有效配置、配置来源、项目配置是否信任 |
| `project.inspect` | `{}` | Xcode 容器、Swift 包、扫描诊断、是否截断 |
| `run.start` | `{"kind":"doctor"}` | 新建的 queued Run |
| `run.start` | `{"kind":"build","container":"App.xcodeproj","scheme":"App","configuration":"Debug"}` | 新建 Run；configuration 可省略，支持 Debug/Release |
| `run.get` | `{"runId":"..."}` | 当前状态与最终结果 |
| `run.list` | `{}` | 历史 Run，按创建顺序倒序 |
| `run.cancel` | `{"runId":"..."}` | `requested: true` 表示发出取消请求；最终状态以 run.get 为准 |
| `run.report` | `{"runId":"..."}` | 已结束任务的 schemaVersion、run、events 和能力范围；运行中拒绝导出 |
| `artifact.get` | `{"runId":"...","name":"stdout.log"}` | name、text、truncated、size；仅 stdout.log / stderr.log，最多返回 256 KiB |
| `run.events` | `{"runId":"...","afterSequence":0}` | events 与 nextSequence，每页最多 1000 条；afterSequence 可省略 |

同时最多一个活动任务。不存在的 run 返回错误；取消已结束的任务返回 `requested: false`，不修改结果。未知或不适用参数拒绝解析。

## 事件与状态

服务端发出 `run.event` notification，params 为事件对象：`schemaVersion`、`runId`、`sequence`、`timestamp`（Unix 毫秒）、`kind` 和 `payload`。

正常生命周期：`run.queued → run.started → step.started → run.completed`。最终状态：`succeeded`、`failed`、`cancelled` 或 `interrupted`。`succeeded` 只表示请求的诊断/构建命令成功，不表示测试或提审通过。

事件可能先于对应 `run.start` 响应到达。客户端应按 runId 分组，用 sequence 去重。收到 `events.gap`、重连或怀疑丢失时，用最后已处理序号调用 `run.events`；若返回 1000 条则继续取下一页，直至空页。

EOF、SIGINT 或 SIGTERM 会请求取消活动任务并保存结果；关闭前最后一个通知可能来不及投递，应通过历史查询获取。异常退出后未终结任务在下次打开相同目录时改为 `interrupted`，不会自动重跑。

## 错误

| code | 含义 |
| --- | --- |
| -32700 | JSON 解析失败 |
| -32600 | 请求结构或帧大小非法 |
| -32601 | 方法不存在 |
| -32602 | 参数非法 |
| -32001 | 尚未初始化 |
| -32002 | 重复初始化 |
| -32003 | 协议版本不支持 |
| -32010 | 项目/运行/配置等领域操作失败 |

`approval.respond` 仍属于未来接口，目前返回方法不存在。`reportExport` 与 `artifactRead` 能力为 true；日志读取校验 run 和实际文件路径，拒绝越界符号链接。事件及运行记录是稳定的产品协议边界；后续 Codex 内部事件需要映射后才能进入此协议。
