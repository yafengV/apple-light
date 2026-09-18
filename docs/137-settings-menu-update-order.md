# 原生设置菜单禁用时序与焦点循环修复

2026-09-18。解决第 136 篇记录的 AttributeGraph cycle 警告，同时覆盖归档项目菜单中此前存在的相同问题。

## 原因与修复

在隔离 XCTest 宿主中用 LLDB 的 `AG::Graph::print_cycle` 断点捕获调用栈。触发路径是 SwiftUI 为原生控件应用禁用环境 → `NSControl.setEnabled` → `NSCell.setEnabled` 寻找下一个有效 key view → `NSHostingView.acceptsFirstResponder` 再次读取正在更新的焦点/布局图。调用栈保存在 `.cache/memory-cycle-backtrace.log`。

`SettingsMenuControl` 现在立即记录请求的启用状态，并立即拒绝禁用时的鼠标、辅助功能、键盘和 action。底层 AppKit cell 的状态更新移到当前视图事务结束之后；仅在自身仍持有焦点时清理它。快速禁用/启用使用 generation 取消过期更新，已被导航转移的焦点不会被异步回调清空。普通设置下拉菜单、平铺筛选菜单和更多菜单复用此修复。

## 验证

- 15 项菜单定向回归通过，记忆及归档宿主此前的 87 条 cycle 警告降为 0。
- 扩大到设置、记忆、归档和快捷键相关的 173 项测试。第一次在受限沙箱内有 5 项因本地 HTTP fixture 无法启动而失败；在允许本地测试服务的环境中重跑，173 项全部通过，0 跳过，0 cycle 警告。最终日志 `.cache/settings-menu-transaction-full-tests.log`。
- 新增检查覆盖：禁用立即拒绝动作/焦点；cell 延后更新；快速禁用/启用不回放旧值；导航已转移焦点时异步禁用不抢回；原有卸载及隐藏菜单保护继续通过。
- 使用项目脚本启动 `/tmp/shipios-settings-menu-validation` 的三条合成记忆和四条合成归档任务，并严格校验签名。
- 原生验证记忆行菜单进入居中确认，底层辅助功能隔离，Esc 返回原菜单，空格重开；切换归档页后焦点停在新页面导航；项目菜单进入两条归档任务的确认，Esc 后返回该项目菜单。未执行永久删除。
- 原工作区随后通过项目脚本恢复，原任务和待发送草稿保留，输入框可聚焦。恢复日志 `.cache/settings-menu-transaction-restore.log`。

这次消除了已复现路径的循环警告，不能据此证明整个应用不存在其他状态循环；全产品逐页视觉和交互配对仍未完成。
