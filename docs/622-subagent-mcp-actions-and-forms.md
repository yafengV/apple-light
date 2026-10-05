# 子任务 MCP 回复接口与详情卡片

接续[原始 MCP 回复绑定](621-native-subagent-mcp-reply-capture.md)。此前子详情不显示 MCP 请求，父回合结束后子任务可能一直等待。本阶段将实际子 MCP 工具审批、服务器表单和 URL 请求接到 Agent 及子详情。所有 UI 对齐、根时间线的子请求汇总及其他权限请求仍未完成。

## 接入范围

| 要求 | 当前行为 |
| --- | --- |
| 原始请求身份 | 根会话拥有一次性 UUID 令牌，记录实际子线程、观察到的活动回合、原始 Core/MCP 回复和原生请求种类。服务器原始 `turn_id: null` 保持，宿主回合放在独立元数据中 |
| 回复 RPC | `codex.subagent.elicitation.resolve` 验证父任务、根/子线程、回合、令牌和原生选项；严格拒绝未知字段/选项、无效内容形状和超过 64 KiB 的内容。类型化字段校验由公共 Swift 表单规则执行，RPC 的基础形状限制不能冒充全部 schema 校验 |
| MCP 工具审批 | 子详情提供允许一次、允许此会话、拒绝、取消。会话授权通过原生回复的 session metadata 进入 Core 策略，不自行绕过工具审批。拒绝不执行实际工具 |
| 服务器表单 | 复用根时间线的类型化表单组件，保留文字/密码、数字、布尔、单选/多选和 JSON、默认值、必填与格式约束。无效值不能提交，拒绝返回 Decline |
| URL 请求 | 仅通过已有 URL 验证后显示打开入口；使用系统浏览器操作，提供完成与取消。完整地址只在子实时状态内存中使用，工作区 JSON 不保存地址/令牌；不作原生 Core 所有文件的泛化隐私声明 |
| 无效/不支持输入 | 捕获请求无法渲染时显示明确原因，保留可用的拒绝/取消入口。无效 URL 不可打开或接受，避免仅显示等待文字而无法结束请求 |
| 多窗口状态 | 所属 WorkspaceStore 共享 pending/resolving/resolved/expired、原生选择、提交锁和错误。字段草稿属于卡片窗口；请求结束后清除字段草稿。旧 revision、错误子/回合、终态后的重新激活均被拒绝 |
| 停止与断开 | 停止关闭原始回复，旧令牌不能消费新请求；同一子的新回合独立。断开清除临时状态、提交锁和错误。父回复及其他任务保持 |
| 持久化边界 | UI 宿主令牌、填写答案和 URL 不写入 workspace JSON。服务器自行返回的工具输出属于原生历史，不能将此项描述为所有底层日志从不包含服务输出 |

主机读子队列时已通过原生子树验证取得加载的 Arc，因此原始捕获直接作用于该 Arc，不在关键路径再扫描数据库。原生终态及 monitor 扫描负责过期，Core 最后的准确回合保护仍保留。此次没有扩展上游 Core/MCP 补丁文件数。

根 MCP 视图保留既有状态与提交通道，仅将可重用卡片拆出；并没有把子回答投递到根会话的回答接口。子详情的普通文字链接继续遵守既有链接偏好，验证按钮明确选择外部浏览器。

## 验证记录

五项新增实际 spawn 集成通过：类型化表单及错误身份/重复令牌拒绝，URL 停止与新请求取消，工具会话授权后的下一轮无需重复审批，表单拒绝的准确 Decline，工具拒绝后实际调用没有执行。父回合均已结束且保留原回复；请求实际经本机 Responses → Core spawn → 子 MCP → Agent → WorkspaceStore 返回，不把固定回复当作真实模型能力。

四项状态/隐藏窗口用例覆盖原生 null turn、字段类型/范围、URL 独立验证、错误子/旧 revision/错误回合/终态重新激活、两种宽度卡片与时间线，以及无效 URL 仍可取消。隐藏窗口尺寸检查不证明实际按键、焦点或完整像素配对。

最终当前 helper 关联 **135 项通过，0 失败/跳过**，39.684 秒，terminal exit 0，`.cache/subagent-mcp-final-associated2.log`。之前六项新专项、八项扩大新专项与 134 项关联结果有重叠，不累加。此次关联集包含根表单/URL/MCP 工具、技能、子任务、准确停止、输入命令和工作区恢复。

Rust workspace **186 项通过，0 失败/忽略**，`.cache/subagent-mcp-rust-final.log`，数量包含 sandboxing 106 项；严格 fmt、Clippy 通过，后者 `.cache/subagent-mcp-clippy-final.log`。最初把常量误引用到 Core API wrapper 导致一次编译失败；后通过 ShipiOS Codex 适配模块正确导出，重新构建及上述最终测试通过，失败日志 `.cache/subagent-mcp-clippy.log` 保留。

固定 Core 五文件/781 个上游文件及 MCP 四文件/51 个上游文件的回放与字节审计再次通过，日志 `.cache/subagent-mcp-core-source.log`、`.cache/subagent-mcp-source.log`。未单独执行上游 MCP 全套测试。

正式包 helper 的同组 **135 项复测通过，0 失败/跳过**，41.592 秒，terminal exit 0，`.cache/subagent-mcp-bundle-tests.log`；与前述 135 项重叠，不累加。严格深度签名、正式包 IPC 和根 Core RPC 冒烟均 exit 0，分别为 `.cache/subagent-mcp-signature.log`、`.cache/subagent-mcp-ipc.log`、`.cache/subagent-mcp-core-rpc.log`。外部浏览器、真实用户服务及真实 OAuth 没有实际验证。

最终 `script/build_and_run.sh` 构建/启动命令 exit 0，Swift 构建 2.51 秒，`.cache/subagent-mcp-app-final-run.log`。新包 Cua 仍返回 Mac 锁定，工作区可交互未验证；启动命令成功不代替这一检查。完整双端配对保持 **0/47**。

第 621 篇推送后全量 handle 24574 正在使用固定副本 `.cache/verified-agent-621/shipios-agent` 及已编译的统一来源 Swift 测试二进制；已确认同一工具 handle 仍在运行。日志 `.cache/full-alignment-regression-621.log`，尚无终态，不重启或覆盖其测试二进制。它不覆盖本阶段新增源码，不宣称本阶段最新全量通过。

## 剩余验收

1. 可交互前台、准确卡片布局、文本与颜色、滚动、键盘/焦点以及 Codex 双端逐项配对。
2. 子请求在根时间线/Activity/通知中的汇总和操作入口；空闲子线程的服务器主动请求、权限请求及其他类型。固定 Core 的结构化提问仍仅支持根线程。
3. 子附件、全部工具呈现、冷恢复与其他执行器，及[全部 29 项核心要求和 47 类页面](599-core-function-parity-matrix.md)。此阶段不将这些剩余项记为已完成。
