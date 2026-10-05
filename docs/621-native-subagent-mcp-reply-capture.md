# 子任务 MCP 原始回复绑定

接续[子任务停止与公共输入器](620-native-subagent-stop-and-composer.md)。子任务详情仍未显示 MCP 表单与 URL 请求；本阶段先实现回复绑定，避免回答被发送到父任务、另一子任务或停止后的新回合。Agent 请求令牌、RPC 和界面留到后续接入，不把本阶段记为子 MCP 交互完成。

## 实际实现与边界

| 请求来源 | 绑定与验证 |
| --- | --- |
| Core 的回合内 MCP 工具审批 | Core 给事件元数据加入自己的递增 generation。声明实际子线程、活动回合、服务器、请求 ID 和 generation 后，才可捕获原始 oneshot；旧 generation 和普通回复不能消费已捕获请求 |
| MCP 服务器 form 与 URL | 保留原生 `turn_id: null`。从固定版本 MCP router 捕获其已生成的全局唯一公开请求 ID，绑定原始回复，不伪造服务器事件的回合 |
| 所属任务 | DescendantSource 验证实际加载的原生子树，拒绝根线程、无关线程、错误回合和冷历史，不为错误操作加载线程 |
| 回答生命周期 | 非 Clone、一次性消费；停止、取消、原回调关闭及请求替换会关闭原始回复。迟到回答不能落到新请求。停止仍使用既有准确回合保护 |
| 后续未实现 | Agent 令牌/RPC、子详情表单与 URL 按钮、空闲时服务器主动请求、其他权限请求和完整 UI 配对 |

两条原生路径不同：工具审批保存在 Core TurnState，服务器请求保存在 MCP runtime router。生产实现保留区别，没有通过改写测试事件的 turn ID 合并路径。固定版本依赖继续为 `50d77959bf927293c4b5ddcca81d05331ae582ea`。

## 固定来源审计

Core 的可审阅补丁扩为五个文件，781 个上游文件与独立 manifest 验证通过；MCP 新增固定版本 vendor，51 个上游文件、四文件补丁及 manifest 验证通过。两份 LICENSE/NOTICE 与上游一致，其他源文件、上游测试和资源逐字节不变。MCP 上游全部测试没有单独执行，不作通过声明。

审计入口为 `script/verify_codex_core_patch.py` 的默认 Core 和 `--component codex-mcp`；日志分别为 `.cache/subagent-elicitation-source-audit.log`、`.cache/subagent-elicitation-mcp-source-audit.log`。普通变更通过 `git diff --check`，两份标准 unified patch 的空白上下文行用独立检查关闭 blank-at-eol 判定；补丁实际回放和字节比较仍通过，不放宽生产源码检查。

## 终态验证

- 三项新增真实 Core 验证：服务器表单的根/兄弟/错误身份拒绝与重复服务器 ID、URL 请求停止后的旧回答拒绝与新请求取消、工具审批 generation 拒绝与实际工具执行。连同已有独立停止用例，专项四项通过，0 失败，1.30 秒，`.cache/subagent-elicitation-native-tests5.log`。
- Rust workspace **186 项通过，0 失败/忽略**，`.cache/subagent-elicitation-rust.log`；含 sandboxing 106 项，不代表全部上游测试。严格 fmt、Clippy 通过，后者 `.cache/subagent-elicitation-clippy.log`。
- Swift 关联 **126 项通过，0 失败/跳过**，64.525 秒，`.cache/subagent-elicitation-swift-associated.log`；正式包 helper 同组复测 126 项通过，38.103 秒，`.cache/subagent-elicitation-bundle-tests.log`。两组相同，不累加。包含现有根会话 MCP、技能、子任务和恢复路径，不声明尚无界面的子 MCP 表单已验证。
- `script/build_and_run.sh` 构建及启动命令 exit 0，`.cache/subagent-elicitation-app-run.log`；严格深度签名、包内 IPC 和 Core RPC 冒烟均 exit 0，分别为 signature/ipc/core-rpc 同前缀日志。模型请求仅为本机夹具。
- 最新正式包 Cua 返回 Mac 锁定，工作区可交互未验证，完整双端配对保持 **0/47**。

失败尝试按原日志保留：夹具最初采用旧工具扁平名称，后改为当前原生 tool search/namespace 协议；原生服务器事件无 turn ID，追踪后接入实际 MCP router；队列屏障实际返回禁用 step_model_switching 的明确 Rejected，测试按真实协议确认命令已处理。没有取消身份、停止或过期保护来通过测试。

先前保留的全量 handle 47011 已 terminal exit 0：**2,660 项 Swift、0 失败、2 跳过**，4561.523 秒，IPC 通过，2026-10-05 11:24:17 结束，`.cache/full-alignment-regression-618.log`。它编译在第 619 篇统一测试 Agent 来源之前，混用旧 helper，不能证明第 619—621 篇或最新统一 Core 全量通过。旧文档的“仍在运行”是当时状态，由此终态记录更新。

## 下一接入

将实际子事件绑定的一次性令牌接到 Agent 和子详情；复用已有类型化表单规则与 URL 验证，保持服务器原始事件、答案不持久化、共享提交/过期状态和所属窗口交互。随后完成附件、权限、冷恢复及[全部核心与页面矩阵](599-core-function-parity-matrix.md)，不缩小全 UI 对齐目标。
