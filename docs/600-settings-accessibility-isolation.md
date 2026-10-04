# 设置页与隐藏工作区的辅助功能隔离

接续[核心与全部页面矩阵](599-core-function-parity-matrix.md) C28。本轮前台发现：设置虽然位于同一主窗口且工作区视觉上透明/禁用，辅助功能树仍包含侧栏、历史和任务输入。只加禁用不能达到页面切换的完整语义，屏幕阅读器仍能遇到不可见内容。

`AppContentView` 继续挂载工作区及已进入的设置页，以保留编辑器、浏览器、终端和输入状态。在二者组合与外层模态控制之间加入独立的 `accessibilityElement(children: .contain)` 边界，让设置及工作区自己的隐藏规则与外层弹层隐藏规则分别生效。不销毁工作区，不用原生额外窗口承载设置，也没有替换控件或修改权限。

## 测试与正式应用

61 项关联回归通过（`.cache/settings-accessibility-boundary-tests.log`）：CommandSearchDialog 5、EditorNavigation 5、PageNavigation 8、PluginSettingsNavigation 5、SettingsInteraction 8、SettingsNavigationKeyboard 2、SettingsNavigation 13、TaskWindowNavigation 4、ThemeCommandMenu 11。该筛选包含类名匹配的 PluginSettingsNavigationTests；不是全应用测试，也不验证实际前台树。

最终源码通过 `script/build_and_run.sh` 正式构建运行，严格深度签名通过（`.cache/settings-accessibility-boundary-app-run.log`、`.cache/settings-accessibility-boundary-signature.log`）。实际读取的工作区仍为 ID main / other，没有持续恢复 loading；实际 ⌘, 打开 ID main / 设置后，树中不再有 SidebarNavigationSplitView、原聊天历史及任务输入，设置控件仍有名称且可操作。

## 本轮逐分类前台记录

逐项点击当前树中实际存在的导航按钮，每一步读取新的完整树，以对应的 `settings-page-heading` 验证标题，并同时检查 ID main 及不存在隐藏工作区/任务输入。下列 **24 个当前可见顶层分类**全部通过这一导航/隔离检查：

| 分组 | 分类 |
| --- | --- |
| 个人 | 通用、通知、语音、个人资料、外观、Agent、个性化、记忆、宠物、快捷键、用量、模型与 API |
| 集成 | 电脑使用、应用快照、插件、浏览器 |
| 编码 | Hooks、连接、代码审查、Git、环境、工作树 |
| 归档 | 已归档任务、运行时 |

这些是当前前台顶层导航数；矩阵中的 26 项设置范围还单列插件子分类，不是额外发现了两页，也不是 Codex 固定的页面总数。这里只验收进入对应页面、同一主窗口和隐藏背景隔离，不能推算为每页所有按钮、像素、错误/取消/恢复均通过。

插件页实际存在 MCP 0 和技能 0 两个子页：分别显示“自定义 MCP 服务器”与“已安装技能”的空状态；已点击技能再返回 MCP，每次检查仍在设置窗口，隐藏工作区没有出现。当前没有安装插件数据，条件显示的已安装插件子页未进行本轮前台验证。

设置内 ⌘K 后，实际树只暴露命令搜索对话框，设置与工作区均隐藏；Esc 关闭后回到原通用设置页，设置搜索恢复焦点。随后逐项分类导航和 MCP/技能子页仍正常。

浏览器页已读取“历史与数据”子页的控件与空状态。尝试继续点击“下载”时 Mac 自动锁定，工具未能确认操作结果；下载、权限子页、最后返回原任务及本轮重启后的返回焦点未继续实操，不记录为通过。锁屏前没有改变模型凭据、权限、主题等设置，也没有点击清理/删除或发送模型消息。

## 保留的验收边界

本轮修复有新的实际前台证据，但不包含 Codex 前台双端操作；完整配对仍为 **0/47**。所有确认弹层、菜单、独立任务窗口、各子页及其他保留视图的可访问性边界仍须逐项验证。后续核心会话和页面完整性继续按第 599 篇推进，不能以本轮 24 次导航通过替代全部交互完成。
