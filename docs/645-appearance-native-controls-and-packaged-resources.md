# 外观原生控件与正式包资源定位

日期：2026-10-07。接续第 644 篇；范围为外观字体/样式、字号、对比度的系统可访问性，以及验收期间发现的正式包资源定位。21 类主窗口、26 类设置和 29 项核心要求保持；完整双端配对仍为 **0/47**。

## 实际缺口与验证范围纠正

当前正式包前台再次确认：字体行只有“界面字体 内容字体 代码字体”文字，字号区域也只有文字；两个对比度滑杆没有出现在完整可访问树中。直接调用已取得的控件对象不能证明用户或辅助工具能够找到它们。

最初测试从隐藏窗口的 accessibilityChildren 开始递归，但该环境只返回 AXWindow/AXGroup，未生成 SwiftUI 系统树。相关 before/after/diagnostic 日志不算生产缺陷基线或修复通过证据。改为遍历原生 representable 叶子，再经 NSAccessibility.unignoredChildren 获取可发现的控件；此时对比度已显式暴露，字体/字号仍产生 14 条失败，日志 `.cache/appearance-native-discovery-before-645.log`、exit 1。

第一轮显式暴露三个控件类型后，36 项、随后加入操作用例的 38 项测试通过，扩大回归 142 项通过。但是正式应用完整可访问树只新增滑杆，字体/字号仍为文字。此结果保留，不能将隐藏窗口原生叶子测试冒充完整页面验收。第一轮日志 `.cache/appearance-native-discovery-after-645.log`、`.cache/appearance-actions-645.log`、`.cache/appearance-formal-associated-645.log`。

## 修订

- 原生字体/样式和共享菜单按钮、字号输入框、滑杆显式设置 accessibilityElement，保留名称、当前值、角色及实际禁用状态。
- 多控件 LabeledContent 的合并语义仍会吞掉字体和字号。新增与原行相同间距/边距的 AppearanceSettingsRow，字体与字号直接使用该行，保留各自可发现的原生控件；原 LabeledContentStyle 共用布局。
- 对比度的启用状态同时核验环境与当前可用条件；实际值变化时发送 valueChanged，失败保存仍读回真实状态。
- 新增三项原生叶子测试，覆盖发现 12 个字体/样式菜单、两个字号和两个滑杆；从发现结果打开菜单、选择 family/style、字号增量后 blur 提交、对比度增量、实际落盘、另一色板/草稿保持，以及恢复中禁用、拒绝操作和重新可用。

## 启动期间发现的资源问题

行容器修订后，原生读取连续超时，随后只读采样 PID 57309。`.cache/appearance-process-sample-645.txt` 的主线程停在 SeededAgentAvatar → AgentAvatar.image → NSBundle URLForResource → CFBundle 目录 open。该次不是把工具超时直接认定为应用故障，而是取得了对应主线程证据。

SwiftPM 生成的资源访问器先查 `.app/ShipiOS_ShipiOS.bundle`，然后回退编译缓存；正式脚本实际把资源装在 `Contents/Resources/ShipiOS_ShipiOS.bundle`。头像和第 644 篇新增主题素材原先直接使用 Bundle.module，因此正式应用仍依赖开发缓存。

新增 ShipiOSResources：正式 .app 只选其自身 Contents/Resources 资源包；缺包不回退开发缓存，继续沿用明确失败而不是从开发机隐藏补全。SwiftPM 测试/非 app 保留 generated accessor。头像和主题素材统一使用该定位。已有代码高亮和主题目录的正式路径原本正确，保持不变。

两项测试覆盖临时移动 .app 的实际资源读取、开发回调未触发、缺包不回退及非 app 的 SwiftPM 分支。修订后的正式包能够再次读取工作区和外观页，实际主题卡片可见、子任务头像入口可操作。本次路径已恢复，不据此宣称桌面文件系统全部阻塞或第 628 篇底层读取问题已修复。

## 最终测试与原生验收

最终 **147 项、0 失败/跳过、68.447 秒、exit 0**，日志 `.cache/appearance-final-associated-645.log`。范围为 Appearance、ThemeCardReferenceTests、AgentAvatarTests、ShipiOSResourceBundleTests、PullRequestCommentMenuTests、SettingsReturnFocusTests、CommandSearchDialogTests。中间 36/38/142/10 项与最终集合重叠，不累加。

正式构建运行 `.cache/appearance-final-formal-run-645.log`、重启 `.cache/appearance-restart-645.log` 和严格签名 `.cache/appearance-final-signature-645.log` 均 exit 0。Rust 生产代码未变；包内 helper SHA-256 仍为 380bec2aac119df2c9755850f1aa6150dd14cb9403a2eb8d42eff39e7f54ae9b。相同 helper 的 IPC/Core RPC 冒烟 exit 0，日志 `.cache/appearance-ipc-645.log`、`.cache/appearance-core-rpc-645.log`。

正式隔离工作区实际操作如下：

1. ⌘, 在唯一主窗口 ID main 进入设置，打开外观。完整系统树显示浅深各三组字体/样式，共 12 个 popup；默认样式正确禁用；两个字号为 stepper、两个对比度为 slider，提供 Increment/Decrement。
2. 点击浅色界面字体，键入 Menlo 后 Return 选择，值变为 Menlo，焦点返回入口，样式变为可用。打开样式选择 Bold，值和落盘 postscriptName 均为 Menlo-Bold。
3. 浅色对比度 Increment 从 45 到 46；界面字号 Increment 产生 15 草稿，Return 提交；代码字号从 12 增至 13 后 Return 提交。磁盘实际保存这些值，深色仍为 60。
4. Esc 返回父任务，父回复保持；打开 Locke 子详情，原历史和 `头像验证草稿642🙂-return643-button643-palette643-theme644` 保持。没有发送模型回合。
5. 正式脚本重启，再次进入外观；Menlo/Bold、15/13、46 均从系统树确认保存。通过菜单 Home/Return、字号 Decrement/Return 和滑杆 Decrement 恢复原设置，完整树与磁盘均核验系统默认、14/12、45/60、system。
6. 顶部截图确认卡片及控件可见；本阶段没有声称整页布局已与当前 Codex 配对。随后通过正式脚本恢复默认 other 工作区（`.cache/appearance-default-run-645.log`，exit 0）；实际点击父输入、⌘, 在 main 打开设置、Esc 返回，同一窗口且输入重新聚焦，没有持续恢复 loading。

## 全量与剩余

第 643 篇固定提交 21dad308b48ec4cfdc1f17c2216166fb014e92d4 的全量继续使用原 session 5404，已重新确认 live，不重启。105 个冻结输入（helper、测试二进制、16 份既有夹具、87 份打包资源）全部哈希保持。该全量不覆盖本阶段；第 639 篇 2,758 项、2 跳过、0 失败及 IPC 的终态记录保持。

当前外观的 Visual style/Advanced 分区、折叠、独立浅深开关及高级重置仍需按当前公开版本实现；完整字体/输入时序、VoiceOver 实际播报、下拉箭头方向、全页颜色/材料/布局仍需继续。当前已查明 La 将 UI family 放在 visual、UI style 放在 advanced，默认只显示有效色板；本阶段修复发现与实际操作能力，不把仍旧的页面结构描述为已对齐。

子任务其余权限/V2 恢复、补丁审批偶发超时根因和矩阵全部剩余范围保留；完整双端配对不增加。
