# 设置返回子任务输入框的原生焦点

日期：2026-10-07。接续第 642 篇。全产品仍为 21 类主界面、26 类设置及 29 项核心要求；本篇不是全部页面完成对齐。

## 实际问题和参考边界

第 642 篇正式包实操中，聚焦子任务输入 → ⌘, → 外观切页 → Esc，原子历史和草稿保持，但键盘焦点落到父任务输入。沿用第 635 篇当前 Codex 公开设置路由的返回来源语义；该静态资源不证明全部原生焦点或双端等价，没有操作 Codex 自身前台。

新增实际 NSWindow、NSHostingView、SubagentComposerView 夹具，保留编辑器、选区、中文草稿和命令归属；模拟设置路由完成早于隐藏工作区重新启用。旧行为一项测试出现两条断言失败（焦点与子输入命令归属），exit 1，日志 `.cache/settings-child-before-643.log`。不删除或放宽原断言。

## 修复

SettingsReturnFocus 为原生 ComposerNativeTextView 使用所属 Coordinator 的待恢复请求。隐藏页面仍禁用时保留请求；SwiftUI 实际启用编辑器时才安排 AppKit first responder 恢复，不通过固定延时猜测启用时刻。

待恢复请求及实际回调均核验原任务/项目、主页面、设置修订、弹层、来源窗口及活动 Coordinator。被移除的子面板、切换任务、新设置进入和新搜索弹层不能借旧请求抢焦点。其他文件/普通页面来源沿用原机制。没有修改草稿内容、发送语义、模型配置或 Rust/Core。

新增三个原生测试覆盖延迟启用后的选区/草稿/命令归属、任务/设置/弹层变化，以及关闭子面板后的失效恢复。测试使用可控 key window 资格；仍须正式包前台复验。

## 最终验证

正式 helper 沿用第 642 篇冻结文件，SHA-256 380bec2aac119df2c9755850f1aa6150dd14cb9403a2eb8d42eff39e7f54ae9b。本阶段 Rust 生产代码没有变化。

- 第一组 19 项原生焦点/输入关联通过，`.cache/settings-child-associated-643.log`；尚未包含最后补充的关闭面板测试。
- 初次扩大回归误设 SHIPIOS_AGENT_PATH，实际使用默认 target/debug helper（SHA-256 945a94dea5212d757a1d56a6e86f1664e2c11b7b64fe79e320d3510307881364），352 项出现 16 条断言失败，`.cache/settings-child-final-associated-643.log`，exit 1。记录保留；该次不能代表正式 helper 的当前原生历史/时间能力。
- 改为正确 SHIPIOS_TEST_AGENT 冻结正式 helper 后，同一最终二进制 **352 项、0 失败/跳过、145.712 秒、exit 0**，`.cache/settings-child-formal-associated-643.log`。范围为 Settings|Composer|Subagent|CommandSearchDialogTests|FileSearchReturnFocusTests|FilePreviewFocusTests|FileTabTests；各组不累加。
- 正式脚本构建运行、严格签名、明确正式包 helper 的 IPC 及 Core RPC 均通过：`.cache/settings-child-formal-run-643.log`、`.cache/settings-child-signature-643.log`、`.cache/settings-child-ipc-643.log`、`.cache/settings-child-core-rpc-643.log`。此前默认 helper 的 IPC 记录另保留 `.cache/settings-child-ipc-default-643.log`。

正式包前台实际验证：子输入 → ⌘, → 快捷键分类 → Esc，返回仍聚焦“子任务消息”，直接键入 -return643 只追加子草稿；再次进入、外观切页、重复 ⌘, 和“返回应用”后键入 -button643，仍只追加子草稿；⌘K → 搜索设置 → Return → Esc 后键入 -palette643，亦归原子输入。父输入为空、父回复及子历史保持，没有发送请求。中间 CUA 截图错误后重新绑定核验实际页面，未把失败的观测当作动作完成。

随后通过正式脚本恢复默认 other 工作区，点击父输入、⌘, 和 Esc 已实际确认同一 main 窗口及父输入焦点。默认恢复日志 `.cache/settings-child-default-run-643.log`。

## 全量与剩余

第 639 篇原全量 session 73780 已取得权威 **exit 0**，固定提交 a2216dba31bbfb228422e16475255adad2d0e72b：**2,758 项 Swift、2 项跳过、0 失败、4,718.284 秒**，随后 IPC exit 0。日志 `.cache/full-alignment-regression-639-final.log`、状态 `.cache/full-alignment-regression-639-final-status.json`。测试输入的 16 个夹具、二进制及 helper 哈希始终保持；这份结果不覆盖第 640—643 篇。

最新源码完整回归仍需取得终态。外观模式卡片的辅助功能独立选项、子任务运行时跳秒/摘要/差异统计/其他权限、V2/其余恢复，以及矩阵全部页面的双端配对继续未完成；完整配对仍 **0/47**。原补丁审批两次超时根因仍未确认。
