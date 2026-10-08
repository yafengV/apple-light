# 菜单关闭与后续导航焦点时序

日期：2026-10-08。接续第 673 篇，处理第 671 篇原生记录中菜单取消与快速 Tab 的恢复时序；保持全部页面／交互及核心功能目标，不把共享控件修复描述为整页完成。

## 参考与证据边界

固定 Codex 26.930.51102 / build 13100，公开 shared JS SHA-256 `eb2500c5398279d4fbf5c71d7ce982d54631660907761740199f6c22591d71ab`。`script/extract_popup_close_focus.cjs` 校验资源，执行实际 DropdownMenuContent 与 Ig 事件组合函数，使用受控 React ref／上下文及 focus 计数替身。六项关闭／外部交互回调结果：正常关闭恢复 trigger，非模态外部左键、模态外部右键／Control 左键或调用方 preventDefault 不强制恢复；实际回调阻止默认关闭恢复。夹具 `popup_close_focus_reference_674.json` 保留边界。

公开 FocusScope 自身使用 setTimeout(0) 执行卸载自动焦点。提取器没有执行 React 生命周期／浏览器计时或真实 Codex 窗口，所以不声称它证明了 Codex 的快速 Esc／Tab 实机时序。原生同步关闭采用相同的关闭焦点策略，解决 AppKit 下一事件被迟到恢复覆盖的问题；同步实现是平台选择，并非从参考源码推导出它也同步执行。双端快速按键配对仍待验收。

## 已复现的问题与实现

旧 SettingsPopupMenuButton 与 AppearanceColorInput 关闭时均将 first responder 恢复排到主队列。其代次令牌只在再次打开／关闭／卸载时失效，不能识别后续 Tab 或用户已聚焦其他字段。因此可能让第一下 Tab 无法从触发按钮出发，或者在后续字段已有选区后将焦点拉回按钮。

六项新增隐藏原生窗口回归在旧实现中失败 8 条断言，2.242 秒（`.cache/settings-popup-focus-before-674.log`，exit 1）。其中 Escape／选择立即返回 trigger 的断言失败，紧接的原生前后 key-view 导航无法获得目标编辑器；后续显式字段聚焦与颜色面板快速 Tab 则在等待后确实被抢回，选区变成空。没有以这些隐藏用例替代前台实际按键。

两种共享控件现在移除浮层后，在当前关闭操作中完成必要的原生 first responder 恢复；删除不再需要的恢复代次与队列任务。保留 active／可编辑／可见／窗口／sheet 保护、鼠标与键盘焦点样式来源，以及 restore:false、选择失败、外部交互与专用 PR 编辑／引用目标的既有策略。后续事件拥有它选择的焦点，不再被本次关闭回调覆盖。

## 验证

首轮关联 **62 项、0 失败／跳过、31.566 秒**（`.cache/settings-popup-focus-associated-674.log`）：六项原生时序全部通过，同时覆盖字体自定义输入／失败、样式与强调色、颜色面板、代码主题和 PR 评论菜单。新回归使用隐藏 NSWindow、真实 NSHostingView／控件／字段编辑器和原生 key-view 导航；不发送系统键盘输入，也不修改用户数据或凭据。

最终扩大回归 **528 项、0 失败／跳过、167.621 秒**（`.cache/settings-popup-focus-expanded-final-674.log`），包含七项本阶段测试及完整设置／外观／命令／恢复／归档／快捷键／个性化／代码主题／PR 评论菜单集合。公开回调提取器再次运行，结果与提交夹具逐字节一致（`.cache/popup-close-focus-reproduced-final-674.json`）。

通过 `script/build_and_run.sh --app` 使用 native-ui-648 构建并执行默认应用启动命令，exit 0（`.cache/settings-popup-focus-final-default-run-674.log`）；Apple Development 严格深度签名通过（`.cache/settings-popup-focus-final-signature-674.log`）。保存第 673 篇 helper 与正式包 CDHash 相同（`.cache/settings-popup-focus-code-equivalence-674.json`）。最终 CUA 仍报告 Mac 锁屏，所以本轮工作区可交互、真实快速按键／点击与重启前台验收待解锁；启动命令成功不等于交互验收完成。最终正式包 IPC 与 Core RPC 冒烟均 exit 0（`.cache/settings-popup-focus-ipc-674.log`、`.cache/settings-popup-focus-core-674.log`）。本轮无 Rust 源码改动，不将历史 Rust 回归当作新运行。

第 673 篇全量仍在原 handle 99495 运行，本轮已在开发后核对冻结的 76 个源夹具、169 个资源、测试执行文件、保存 helper 与参考 CSS 未变（`.cache/full-alignment-regression-673-mid-audit.json`）；这不是其终态验证，也不覆盖本轮改动。

## 剩余范围

所有窗口激活／失活与焦点来源、参考弹层材料／阴影／位置／动效、macOS 14 实机、真实用户服务、完整逐页交互及快速按键双端验收仍缺。完整范围保持 21 个主页面／交互类别、26 个设置面及 29 项核心功能，完整配对仍 **0/47**，不换算为代码完成率。第 673 篇冻结全量在 native-ui-654 原进程运行；本轮使用已释放的 native-ui-648，不改它的执行文件、资源或已捕获夹具。
