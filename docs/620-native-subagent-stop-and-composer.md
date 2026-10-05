# 子任务独立停止与输入命令归属

接续[原生子审批](618-native-subagent-approval-actions.md)和[测试 Agent 来源统一](619-integration-agent-source-unification.md)。子详情此前缺少停止入口，输入使用独立 TextEditor，主菜单和额外快捷键可能操作父任务。本阶段接入实际子回合停止和公共原生输入器；没有将完整子会话或其他页面记为对齐完成。

## 实现范围

| 要求 | 实际行为与边界 |
| --- | --- |
| 停止所选子任务 | `codex.subagent.interrupt` 必须提供父任务、根线程、实际子线程和观察到的活动回合。Core 直接调用已有原子 guarded abort；旧操作不会通过队列选中下一回合 |
| 身份验证 | 拒绝根线程冒充子线程、其他根任务和子树外线程。未知、已卸载和冷历史不因停止操作而加载；已结束/已替换回合返回明确失败 |
| 保留结果 | 停止保留部分子回复与窗口草稿，父任务和其他并行任务继续。审批等待被中断后原请求过期，迟到批准不能执行工具 |
| UI 状态 | 所属 WorkspaceStore 共享提交锁、错误和目标回合；按钮显示提交中，失败可见。回合身份保护避免旧收尾清除新操作；断开时清除临时状态 |
| 公共输入器 | 子详情使用与主输入区相同的 AppKit 富/纯文本编辑器，遵守三种 Return 偏好、⌘Return、换行、中文组合输入和空草稿向上恢复自己的上一条消息 |
| 菜单与快捷键 | 通过当前 NSWindow 的实际 first responder 定位子输入器。发送、引导、停止、清空草稿属于当前子任务；拥有但不可用的命令会被禁用/消费，不落到父任务。默认和用户额外绑定均按现有 ShortcutPreferences 解析 |
| 输入法边界 | 组合文字期间发送/引导被消费但不发送；明确停止仍可作用于子回合。主窗口和任务窗口保留已有模态、sheet、设置及录制快捷键保护 |
| 附件 | 尚未接入子附件请求；粘贴附件显示当前文字限制说明，不静默吞掉，也不转移到父任务。完整附件能力继续属于缺口 |

Core 只增加 `interrupt_turn_if_active` 公开入口，原先四文件补丁没有扩为更多上游文件。该 API 和主机子树身份检查分别负责回合与线程边界。此停止入口只针对所选子回合，不把其孙任务、Node executor 或所有后台执行器记为已停止。

## 验证记录

真实 Core 专项验证子停止保留根/兄弟/无关线程、原始审批关闭、新回合同 call ID 和旧停止拒绝、已卸载子线程拒绝；最后冷历史断言先修正夹具：Shutdown 并不等于 ThreadManager 已移除，需要明确 remove_thread。没有放宽生产身份保护。专项 1 项通过，`.cache/subagent-controls-native-stop-final.log`。

Swift 新增真实 IPC/本机 Responses 流程：部分文字后停止、父与另一任务继续、草稿保留、恢复子续聊、旧回合停止不能影响新回合，以及原子审批过期后不执行。隐藏原生窗口验证三种发送偏好、busy/禁用、实际 marked text、first responder 和自定义绑定；不将隐藏窗口结果当成可见页面验收。第一轮纠正未绑定 ⌘⇧Return 的测试假设：AppKit 可以忽略该按键，不应强制断言插入换行；生产输入语义没有为测试改写。

最初 11 项输入/停止专项及扩大 57 项通过，`.cache/subagent-controls-swift-final.log`、`.cache/subagent-controls-command-regression.log`。最终组词保护、额外绑定及关联复测 **100 项通过，0 失败/跳过**，21.950 秒，terminal exit 0，`.cache/subagent-controls-final-associated-allowed.log`；各集合有重叠，不累加。包括实际父/子/并行任务、停止后的审批过期，以及主窗口在组合输入期间将额外 Stop 绑定投递子输入器、消费发送和保护模态入口。

Rust workspace 183 项通过、0 失败/忽略，`.cache/subagent-controls-rust.log`；严格 Clippy 和 fmt 通过，`.cache/subagent-controls-clippy.log`。源码审计确认固定版本 781 个上游文件、四文件补丁及独立 manifest，`.cache/subagent-controls-core-source-final.log`。Rust 数量包含 vendored sandboxing 的 106 项，不代表全部上游 Codex 测试。

本轮一次沙箱复测无法启动本机服务：独立 socket bind 直接返回 PermissionError，测试记录失败后主动结束该次，不计通过。日志 `.cache/subagent-controls-final-associated.log` 已记录此次失败；最终正常复测使用独立日志。一次正式构建的编译与打包成功，但沙箱下 LaunchServices 返回 -10827，启动不计通过，`.cache/subagent-controls-app-run.log`；正式启动需在允许启动的环境重新验证。

允许启动后，通过 `script/build_and_run.sh` 重新构建并启动正式应用，terminal exit 0，Swift 构建 3.96 秒，`.cache/subagent-controls-app-run-allowed.log`。严格深度签名、正式包 IPC 和 Core RPC 冒烟均 exit 0，`.cache/subagent-controls-signature.log`、`.cache/subagent-controls-ipc.log`、`.cache/subagent-controls-core-rpc.log`。这些 Core 请求只连接本机夹具，不代表真实模型或用户服务验证。

正式包 helper 的同组 100 项复测通过、0 失败/跳过，18.287 秒，terminal exit 0，`.cache/subagent-controls-bundle-tests.log`；与前述 100 项重叠，不累加。最新 Cua 获取正式应用仍返回 Mac 锁定，**工作区可交互未验证**，不能用启动命令成功替代。完整双端配对继续 0/47。

## 继续验收的内容

1. 实际可操作窗口；精确视觉、焦点、滚动、键盘与两端逐项配对。最新源码全量仍需单独完成，不能拿旧二进制结果代替。
2. 子会话 MCP 表单/URL、权限请求和其余原生审批类型；固定 Core 的结构化提问目前仅支持根线程，不能去掉限制伪装已对齐。
3. 子附件、全命令选择、查找/滚动、冷恢复、孙任务/Node executor 及其他执行边界。
4. [全部 29 项核心要求及 47 类页面范围](599-core-function-parity-matrix.md)。完整双端配对仍 0/47；当前全量 47011 编译在 Agent 来源统一及本阶段之前，保留运行，不替换其 helper、测试二进制或服务器夹具。
