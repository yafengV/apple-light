# 窗口重新激活后的重命名焦点

日期：2026-10-10。开发基线 `48b0244`。本篇补 R3／R7／R8 的通用弹层焦点和部分实际导航证据，R1–R8 的交付范围不变。

## 实际缺陷与修复

在隔离夹具的实际 ShipiOS 主窗口中，从侧栏右键菜单打开任务重命名后，名称框没有获得焦点，直接粘贴中文没有改变输入；Esc 可以关闭并回到输入框。`RenameDialogKeyboardBridge.capture` 原先只排队一次焦点请求，如果窗口当时不是关键窗口，请求便被丢弃。

协调器现在保存尚未完成的初次焦点请求，并监听当前所属窗口的 `didBecomeKeyNotification`。窗口成为关键窗口、桥接仍挂载在该窗口且键盘监听仍有效时，才请求名称焦点和全选；完成后移除窗口观察，后续激活不再重发。关闭／拆除时清除待处理状态和观察，其他窗口的通知不会触发此弹层。

新增实际原生回归：先在尚未成为关键窗口的窗口中挂载重命名，再显示窗口，验证名称编辑器、初始全选、用户编辑后再次激活时保留文字和末尾光标，以及取消后原标题不变。前台宿主现在明确选择 **3 项**，运行器同样要求实际执行 3 项、0 失败／异常／跳过才通过。

## 验证

- 修复前的独立原生宿主：**3 项、1 条失败断言、0 跳过**，新方法无法取得名称 field editor；冻结输入未变。两项旧方法通过。`.cache/rename-late-key-baseline-737/` 保留失败。
- 首次修复后初次焦点和全选通过，但新测试末段原先使用 `makeFirstResponder(host)`，误假定这能改变 SwiftUI FocusState；复验失败 1 条“必须保持 host responder”断言，记录在 `.cache/rename-late-key-fixed-737/`。最终场景改为实际用户输入后切窗，检查文字和光标不得重新全选，不以任意 responder 身份替代用户行为。
- 最终原生宿主：**3 项、0 失败／异常／跳过、19.489 秒**，源码、测试包、资源和 helper 冻结输入未变。延迟成为关键窗口的新回归，以及此前的同窗口改名／工作树取消继续两项均通过。`.cache/rename-late-key-caret-final-737/{test.log,result.json,manifest.json}`。
- 关联命令行回归：`TaskRenameTests`、`TaskRenameHistoryTests`、`PinnedBrowserRenameTests`、`RenameDialogPresentationTests`、`BrowserTabRenameTests` 共 **40 项、0 失败／跳过、6.064 秒**，冻结输入未变。两项 PinnedBrowserRename 前台方法明确排除，已在上述宿主验证；没有把它们作为命令行通过。`.cache/rename-associated-737.log`、`.cache/rename-associated-manifest-737.json`。
- 通过 `script/build_and_run.sh` 标准独立打包和启动，实际侧栏菜单打开后名称自动全选，**不点击输入框即可粘贴中文替换**，回车保存更新侧栏和标题，关闭弹层并返回输入框；重命名未选中的任务不切换当前聊天。
- 同一最新隔离实例中，切回来源任务恢复原草稿；中文搜索过滤到正确工作树，回车打开该任务并聚焦输入框。归档非当前本地任务保留当前工作树聊天；主窗口内的归档设置能恢复正确任务，呈现“暂无已归档任务”。最终保存文件确认 3 个任务均未归档、来源草稿保持原值。
- 恢复通知出现“查看”，但点击前已过期，工具返回失效元素 ID；**通知跳转归属尚未通过验收**。本篇不将其记为成功。
- 稳定 Apple Development 签名与第 713 篇旧身份要求、严格深层验证通过，最新打包 helper IPC 冒烟通过。验收后已用标准脚本恢复默认实例，实际主工作区无持续 loading，输入框可点击聚焦；没有读取个人 Codex 认证或填写用户 API。

隔离实际页面证据在 `.cache/interactive-navigation-737/{rename-focus-baseline.json,fixed-ui-evidence.json}`，包含包哈希及自建夹具的最终任务／草稿状态。构建／启动记录为 `.cache/rename-late-key-package-737.log`、`.cache/rename-late-key-product-launch-737.log`、`.cache/rename-default-launch-737.log`，IPC 记录为 `.cache/rename-ipc-737.log`。这些运行数据和缓存不进入提交。

本轮没有重跑最新全部广泛回归。真实 API 服务仍待用户在设置保存；通知返回、独立任务窗口及冷恢复、其余页面／键盘／错误状态和真实模型开发闭环继续验收，不能据局部成功宣称核心完整对齐。
