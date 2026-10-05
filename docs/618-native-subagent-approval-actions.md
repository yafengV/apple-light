# 子任务详情中的原生审批操作

接续[原始回复绑定](617-native-approval-reply-capture.md)。本阶段把原生命令/补丁审批接到 Agent 请求令牌、独立 RPC 和子详情卡片。结构化提问、MCP elicitation、权限请求和全部子会话呈现仍缺；完整目标和 0/47 双端配对口径保持不变。

## 已接入的行为

| 内容 | 当前实现 |
| --- | --- |
| 原始请求认领 | 所属父任务的实际子事件读取器由真实子树验证取得 native Arc，直接在该线程上认领原始 waiter（避免再次扫描图数据库失败使审批失去操作入口），再把一次性 UUID 和原生选项放入已经有完整分块/摘要校验的公开事件；不按 call ID 重新提交审批 |
| 允许选项 | Exec 使用 Core 的 effective_available_decisions；补丁使用原生支持的一次、会话缓存和整回合 Abort。RPC 只接收索引，不能由客户端伪造前缀/网络策略内容 |
| 身份与重复 | 校验所属父任务、根线程、子线程、回合和令牌；无效身份/选项不消耗原始待审批记录。成功操作先移除能力；重复或迟到请求不能操作新请求 |
| 独立状态 | pending → resolving → resolved/expired 通过父任务所属的独立控制事件发送，带单调版本；不会追加父回复、创建父工具卡或终止父流 |
| 过期和取消 | 原生终止/关闭及发现 tick 检查关闭的原始等待；已过期/已处理不重新开放。显式拒绝使用原生 Abort，只停止该子回合 |
| 子详情卡片 | 在原始审批事件的位置显示命令/修改路径和原因、实际可选按钮、提交中/已处理/过期和错误。横向空间不足时转为纵向；文字可选择，按钮有稳定辅助功能标识 |
| 多窗口归属 | 审批状态、提交中锁和错误由 WorkspaceStore 共享；选择、输入草稿和父回复仍独立。损坏的实时流禁止继续操作；根会话替换/断开清除临时状态 |
| 持久化 | UUID 与原始回复能力仅存在运行时；不把可操作令牌写入 workspace.json。历史审批不能凭过时 call ID 重获批准能力 |

## 验证与当前边界

- 第一轮新增 Swift 测试编译发现夹具语法、异步 XCTUnwrap、目录字段及闭包声明错误，已修正。初次 Clippy 发现 actor 参数过多，改为明确的 RootActorContext；严格 Clippy 后通过，不添加宽泛豁免。
- 第一轮真实集成等待超时，诊断定位到 HTTP 夹具用临时目录名误识别子请求，让父回合先执行需审批的工具。改用专用原生子请求标记；生产审批路由不为夹具放宽。
- 四项专项通过，0 失败/跳过，1.784 秒，`.cache/subagent-approval-routing-swift3.log`：真实 spawn 子线程批准后写入、错误子身份拒绝、令牌只用一次、拒绝时实际子回合中断且不执行、父回复保持，以及过期版本保护、命令/补丁卡窄宽隐藏原生布局。
- Rust workspace 182 项通过，0 失败/忽略，terminal exit 0，`.cache/subagent-approval-routing-rust.log`；严格 workspace Clippy 通过，`.cache/subagent-approval-routing-clippy2.log`。固定四文件 Core patch 未进一步修改。
- 扩大后的 **82 项关联回归通过，0 失败/跳过**，147.393 秒，`.cache/subagent-approval-routing-associated.log`，含取消→新回合同调用 ID 的过期令牌拒绝、伪造选项不消耗原请求、workspace.json 不含令牌及关闭清理。
- 追加实际只读子线程的补丁会话授权后，**30 项专项通过，0 失败/跳过**，11.851 秒，`.cache/subagent-approval-routing-patch-final.log`。与 82 项有重叠，不能相加；真实补丁经同一 child RPC 批准前无文件、批准后写入，父回复保持。
- 改为已验证 native Arc 直接认领后，最终 Rust 182 项通过，严格 Clippy 和 Agent 构建通过，`.cache/subagent-approval-routing-rust-final.log`、`.cache/subagent-approval-routing-clippy-final.log`、`.cache/subagent-approval-routing-agent-final.log`。无令牌的历史审批显示历史记录，不冒充仍在等待操作。
- 最终关联集合 89 项通过、0 失败/跳过，152.796 秒，`.cache/subagent-approval-routing-final-associated.log`。复核发现其中六项旧根会话集成固定使用默认 `target/debug`，不遵循本轮 Agent 路径；该次只有其余 83 项具有当前 helper 来源。将六项改为 `AgentTestExecutable.url()` 后，单独重跑六项通过、0 失败/跳过，5.530 秒，`.cache/subagent-approval-routing-root-helper-final.log`；包括命令/补丁审批、结构化提问及 MCP 审批/表单/URL 流程。不是重新运行全部 Swift 测试。
- `script/build_and_run.sh` 在独立缓存构建并启动正式包，exit 0，Swift 构建 2.77 秒，`.cache/subagent-approval-actions-app-run.log`；严格深度签名、包内 IPC 和 Core RPC 冒烟均 exit 0，日志分别为 `.cache/subagent-approval-actions-signature.log`、`.cache/subagent-approval-actions-ipc.log`、`.cache/subagent-approval-actions-core.log`。
- 最终正式包 helper 的 12 项复测通过、0 失败/跳过，11.564 秒，`.cache/subagent-approval-actions-bundle-tests.log`：四项实际原生子审批流程、两项模型/隐藏窗口检查及上述六项根会话流程。与前述集合重叠，不累加。
- 本轮 Cua 获取最新正式应用仍返回 Mac 锁定，不能确认新包工作区可交互；前台检查需解锁后接续。隐藏 NSHostingView 尺寸验证不代表实际 Tab/Return 操作或精确 Codex 布局验收，完整双端配对继续 0/47。
- 保留全量 handle 77058 已确认 terminal exit 0：`d84d0f9` 编译的 2,654 项 Swift，0 失败、2 跳过，4,587.075 秒，及 IPC 冒烟通过，`.cache/full-alignment-regression-616.log`。它仍不覆盖第 617/618 篇，不能描述为本阶段全量通过。

## 仍需继续

1. 子会话 MCP 表单/URL elicitation、权限和其他原生审批来源的完整操作；结构化提问需区分当前 Core 的根线程限制并核对参考行为，见[第 619 篇](619-integration-agent-source-unification.md)。
2. 子审批完整视觉/焦点/键盘配对、精确策略说明、通知与 attention；所有真实服务及网络/前缀变体的完整前台流程。
3. 子会话单独停止、冷恢复、全部工具/附件/输入、查找/滚动及长会话性能。
4. 完整逐页双端验收和[其他核心/页面缺口](599-core-function-parity-matrix.md)，目标保持未完成。
