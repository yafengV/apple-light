# 设置共享控件的焦点自动显示

日期：2026-10-08。继续全部 UI／交互与核心功能对齐，修复第 667 篇按钮以外的设置控件聚焦后仍留在屏幕外的问题。

## 依据与改动

实际原生复现：从设置搜索开始，Tab 经过 24 个导航项，再经过八个通用页控件，焦点已到“音频可视化”，页面仍停在文件打开方式／权限区域，开关不可见。修复后按完全相同顺序，开关实际进入视口并显示焦点轮廓，没有激活音频权限或改变开关。

第 667 篇的公开按钮组件和既有共享开关／选项参考采用浏览器控件。浏览器默认在聚焦时显示目标，参见 [MDN HTMLElement.focus](https://developer.mozilla.org/en-US/docs/Web/API/HTMLElement/focus)。这是应保持焦点可见的依据，不能单凭该规范证明 Codex 的所有滚动位置、弹层和焦点来源都一致；本阶段没有新增 Codex 双端页面验收。

- 将页面已有的焦点显示环境提取到 `SettingsFocusReveal.swift`。每个控件拥有稳定 UUID，只在实际获得焦点时通知当前页面，继续使用既有 ScrollViewReader 的最小距离滚动，不增加窗口、滚动容器、全局事件监听或额外 Tab 停靠点。
- 动作按钮、共享开关、独立选项按钮复用已有 FocusState；文本框与密码框观察它们自己的编辑焦点，不给文本输入额外套 focusable。
- `SettingsMenuPicker` 的原生菜单在接受 first responder 后异步通知；回调再次核对启用、可见、活动状态及实际 first responder。
- 多行编辑器拆为保持原调用接口的 SwiftUI 外层和 `SettingsTextEditorContent` 原生输入，提供稳定滚动目标；保留原绑定、选区、输入法、撤销、Tab 和 focusRequest 逻辑。原生编辑器在当前可编辑／可选择且仍持有焦点时才通知；拆除时清除通知。
- 第 667 篇的页面回调继续核对设置目的地与当前页，隐藏的保留页面不能滚动当前页。普通重新绘制、文字或选区变化不会持续把视口拉回已经聚焦的控件。

## 自动化验证

最终扩大 **475 项、0 失败／跳过**，143.138 秒，日志 `.cache/settings-focus-final-expanded-668.log`；使用本阶段正式包保存的 helper，覆盖设置、外观、桌面命令、恢复、归档、快捷键和个性化。此前专项 **28 项、0 失败**，13.103 秒，日志 `.cache/settings-focus-associated-final-668.log`，与扩大范围重叠，不累加。

新增三项原生回归：

1. 四种真实原生输入（文本、密码、菜单、多行编辑器）在距顶部 700 点的离屏位置接受焦点后，目标完整进入视口；中文文本和菜单选择保持，菜单／编辑器聚焦不提交值。
2. 输入框保留实际编辑器和中文选区；用户滚离聚焦输入框后，普通页面更新不再次抢回视口。
3. 原生菜单与编辑器的失焦、隐藏、禁用和拆除状态拒绝迟到通知；当前可用编辑器正常通知。既有原生拆除、编辑器身份与加载／失败恢复测试也通过。

早期夹具错误地把 visibleRect 非空当作可见，而且普通隐藏窗口的 selectNextKeyView 没有移入目标；诊断结果未作为通过证据。现使用实际接受的 first responder，并核对目标 bounds 与 visibleRect 的交集。修复前四类控件的可见性断言均失败，日志 `.cache/settings-focus-native-before-668.log`；额外两条文本绑定次数断言反映原 SwiftUI 的相同值回写，最终按实际文字保持验证，不声称修复此既有回写。编辑器拆分时两轮编译分别暴露 coordinator 和另一份既有测试的旧类型引用，修正后全部扩大通过，失败日志 `.cache/settings-focus-associated-668.log`、`.cache/settings-focus-associated-fixed-668.log` 保留。

最终页面／子页图位于 `.cache/settings-focus-final-668-snapshots`；已查看最终 Git 页及前阶段同页，上方布局保持。离屏截图不能替代实际键盘和双端验收。

## 原生验收与持久化

通过标准 `script/build_and_run.sh` 构建、开发签名并启动自有 `.cache/settings-focus-native-668/Data`；只复制自有工作区 JSON，没有复制 API 配置或凭据。

- 通用页沿相同 32 次 Tab 顺序显示原先离屏的开关；继续到下方菜单／开关／选项后，“引导当前运行”的按钮和焦点轮廓也可见。Return 选择该项，Shift-Tab／空格恢复“等待下一轮”，焦点保持。
- 实际点击 24 个设置导航页，检查内容和主窗口 ID main；插件的技能／MCP 两个子页均实际切换。仅验证这些路径，不代表每页所有状态已完成。
- Git 页从分支前缀经 Tab 到 PR 监控编辑器，继续 Tab 到目录选择；反向七次回到上方输入框时，页面滚回并显示原文字选区。仅在自有测试工作区输入中文指令，自动保存及 JSON 值确认成功。
- API 页从基础地址经键盘到模型、语音模型、协议及空的密码框；协议用 Return 打开、Escape 取消并保留原菜单焦点。没有填写密钥、保存配置或调用用户服务；之后进入个性化没有出现虚假的未保存确认。
- 个性化编辑器 Shift-Tab 跳过禁用保存按钮回到建议开关，Tab 返回实际编辑器，没有插入制表符。
- 标准脚本重启后原任务、中文草稿“设置焦点原生验收草稿668”及已自动保存的中文指令仍在；编辑器可继续获取焦点及 Tab 移出。同窗口退出设置后任务输入框实际取得焦点。

构建／重启日志 `.cache/settings-focus-native-{run,restart}-668.log`。最终标准脚本恢复默认工作区 other，实际任务输入框取得焦点，日志 `.cache/settings-focus-default-run-668.log`；原生观测汇总为 `.cache/settings-focus-native-evidence-668.json`。

## 完整性与剩余范围

保存 helper SHA-256 为 `f800c6adb6479543f4307325b7fd40a1042f76ba5dea785a6b0619e3a336fb8b`。IPC 与正式包 Codex Core 本地回环服务均 exit 0，日志 `.cache/settings-focus-{ipc,core}-668.log`。最终正式包严格深度签名 exit 0，保存／包内 helper 的 CDHash 相同，日志 `.cache/settings-focus-final-signature-668.log` 与 `.cache/settings-focus-code-equivalence-668.json`。没有 Rust 源码改动，不声称重跑 Rust 全套或真实用户服务。

第 666 篇提交 9336030 的全量回归仍使用冻结 native-ui-648；本阶段使用 native-ui-654。再次核对 70 个源夹具、163 个包资源、测试执行文件及保存 helper 均未改变，并通过原进程 handle 确认仍运行；不把运行中的结果计为通过，它也不覆盖本阶段。

独立原生 Picker／滑杆／字号步进器、动作菜单、其他未采用共享控件的字段、所有弹层与焦点来源、精确滚动位置和视觉动效、macOS 14 实际运行、真实用户服务与每页全部行为仍需继续。Codex 窗口操作此前受工具安全限制，没有绕过。完整范围保持 21 个主页面／交互类别、26 个设置面及 29 项核心功能，完整双端配对 **0/47**，不是代码完成比例。见[完整矩阵](599-core-function-parity-matrix.md)。
