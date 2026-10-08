# 语音设置共享卡片与实际页面顺序

日期：2026-10-08。接续第 676 篇，处理语音页面仍使用旧卡片／开关的差异。全部 UI 交互与核心功能目标保持。

## 公开参考与本轮实现

从已安装应用的公开分发资源取得 `voice-settings-1053b1128b33.js`，SHA-256 `dcac6c84dc913e502511a3c408178dad8266acbd53fe463c312c7dcb5757055f`；它直接导入此前固定的 `app-shared-9d148924be0b.js` 与 `app-initial-f9b16fbf8fc7.js`，沿用 Codex 26.930.51102 / build 13100 参考。没有读取账户、模型凭据或个人配置，也未绕过 Codex 窗口操作限制。

新增 `script/extract_voice_settings_layout.cjs`，对实际 `bn`／`tn`／`En`／`On`／`In` 执行惰性 hooks 夹具，验证通用／语音聊天／听写／词典的顺序、麦克风／语言的顺序、音色／热键／屏幕上下文的顺序，以及听写提示音／快捷键／最近录音卡片、独立词典卡片和录音的 compact 行结构。输出 `voice_settings_layout_reference_677.json`，重新执行结果逐字节一致。账户及设备能力、权限请求和被保留的子组件没有执行，不能当作这些路径已经验收。

- 语音页改用共享 `SettingsSection`、卡片、行标签、动作按钮和设置开关；移除页面内旧毛玻璃、14 点圆角、15 点半粗分区标题及重复行边距。默认行使用第 664／669 篇已经取得的参考，保持单一滚动文档和共享页面分区间距。
- 页面改为通用 → 语音聊天 → 听写 → 独立词典。麦克风先于语言；语音热键先于屏幕上下文；最近录音放在听写区，先于词典，与快捷键卡片之间为共享 Content 的 6 点间距。
- 音色指示点改为参考的 12 点并使用主题强调色。屏幕上下文接入第 676 篇开关的释放／取消语义。无错误时语音分区不保留空 footer 的额外间距。
- 词典使用共享卡片背景、边框和分隔线；条目按公开 `nested` 行的 16 点左右／8 点上下边距、40 点最小高度绘制，添加按钮补加号。词条 ID、编辑、插入、移除与保存动作保留；记录菜单、下载、删除、转写以及快捷键录制实现保留。
- 补查实际 `In` 确认录音使用 compact 行，不能套普通行的 12 点上下边距。提取 `VoiceRecordingSettingsRow`，使用 8 点上下边距、共享标签／说明行高和 2 点间距及控件保留区；完整页面直接使用该组件，没有测试专用尺寸实现。

## 验证与限制

初版测试将完整 AppKit 辅助功能协议名写错，属于夹具编译错误。修正后旧代码 **3 项、5 条失败、2.597 秒**（`.cache/voice-settings-layout-before2-677.log`）：四条是两个宽度下麦克风顺序及右边缘的实际差异；一条来自隐藏 NSHostingView 的辅助功能 children 为空，不能计为产品页面标签缺失。后者经单独诊断确认后移除该无效测试，不放宽产品断言，也不以它证明页面排序。排序另由公开函数、生产代码及实际离屏整页图核对。

首轮共享迁移 **13 项、0 失败／跳过、3.990 秒**（`.cache/voice-settings-layout-focused-677.log`），补开关接入后 **14 项、0 失败／跳过、5.361 秒**（`.cache/voice-settings-layout-focused-final-677.log`）；录制补充后 **15 项、0 失败／跳过、7.278 秒**（`.cache/voice-settings-layout-focused-final3-677.log`）。最终定向 **16 项、0 失败／跳过、7.844 秒**（`.cache/voice-settings-layout-focused-final5-677.log`），新增五项原生验证：

1. 760／400 点宽度下麦克风先于语言、右端为页面边距 20＋卡片行边距 16，且只有一个滚动文档。
2. 中文词条仍在编辑时，改变模型配置条件行和窗口宽度，原 NSTextField、编辑器、焦点、内容与选区不变；失焦后保存词条。
3. 从实际语言下拉响应器经过三个 Tab 到屏幕上下文，用自有隐藏窗口 `sendEvent` 分发 Space：按下不保存、松开切换，磁盘重读为 true，语音会话未启动。没有系统键盘注入、录音、屏幕读取或真实 API 请求。
4. 从语言经过两个 Tab、Return 创建语音快捷键录制器；明确聚焦实际原生字段后，输入组合键保存并从磁盘恢复，重新进入后 Escape 取消不改绑定，录制活动计数回到零、字段卸载。
5. 实际录音行组件在 700／400 点宽度的自然高度，符合上下各 8 点＋18 又 4/7 点标签行高＋16 点说明行高＋2 点间距。完整页面的含文本／音频重试录音图另行检查。

第四项初次失败六条断言（`.cache/voice-settings-layout-focused-final2-677.log`）；诊断确认隐藏窗口 `isKeyWindow=false`，录制器按设计不会在非活动窗口自动抢焦点（`.cache/voice-settings-capture-diagnostic-677.log`）。测试仅在真实非 key 状态下明确聚焦字段，没有伪造 isKeyWindow、取消保护或声称前台自动焦点通过。生产录制器未改。无错误的语音分区移除空 footer 后，也显式保留原有错误提示的 caption 字号。

第五项最初尝试查找带“录音操作”标签的 NSButton，但 SwiftUI Menu 没有这种原生子按钮，得到零个而不是两个，出现一条夹具断言失败（`.cache/voice-settings-layout-focused-final4-677.log`）。没有以它推断菜单不可操作；改为测量生产实际行组件，不依赖 Apple 私有视图类型或把生产尺寸反抄为预期。

已检查 `.cache/voice-settings-layout-final-677.png`、`.cache/voice-settings-layout-full-677.png` 及最终 `.cache/voice-settings-recordings-final-677.png`：未配置提示、已配置整页及两种录音行均呈现预期顺序、共享卡片与开关。录音菜单仍可见原生额外箭头，完整样式另待对齐。这些是自有 NSHostingView 的离屏渲染，不代替前台点击、滚动或完整 Codex 双端配对。

首轮扩大 **574 项、0 失败／跳过、177.526 秒**（`.cache/voice-settings-layout-expanded-final-677.log`），提示字号及录制补充后 **575 项、0 失败／跳过、179.447 秒**（`.cache/voice-settings-layout-expanded-final2-677.log`）；两者不覆盖此后的 compact 录音组件。最终扩大 **576 项、0 失败／跳过、183.238 秒**（`.cache/voice-settings-layout-expanded-final3-677.log`），覆盖最终代码的设置／外观、桌面命令、恢复、归档、快捷键、个性化、代码主题／PR 评论菜单、修饰键语音快捷键、录音历史、全局听写及草稿插入。

通过标准 `script/build_and_run.sh --app` 完成最终构建与启动命令，exit 0（`.cache/voice-settings-final-default-run-677.log`）。受限签名校验先返回 `CSSMERR_TP_NOT_TRUSTED`（`.cache/voice-settings-restricted-signature-677.log`），与该环境不能访问钥匙串信任链一致；在正式签名所用的访问环境中严格深度校验通过（`.cache/voice-settings-final-signature-677.log`）。指定要求解析最初只读 stderr 而漏掉 stdout，修正读取两路输出后比对通过；不是应用签名身份变化。

正式 helper 与本轮测试保存的第 673 篇 helper CDHash 一致；此次主应用 CDHash 已变化，但主应用及 helper 的指定要求都与本轮重建前一致（`.cache/voice-settings-code-equivalence-677.json`）。正式包 IPC／Core 本地服务冒烟均 exit 0（`.cache/voice-settings-ipc-677.log`、`.cache/voice-settings-core-677.log`），没有调用用户实际 API。本阶段没有 Rust 源码变化，不把历史 Rust 回归当作新运行。

最终 CUA 仍报告 Mac 锁屏，因此本轮前台工作区可交互、所有点击／滚动／快捷键、重启状态及重复文件夹授权提示继续待验；不将启动命令成功或隐藏窗口事件视为前台通过。

第 673 篇原全量已 exit 0：2,907 项、2 跳过、0 失败及 IPC 通过，终态核对 76 个已捕获源夹具、169 个包资源、测试执行文件、保存 helper 及参考 CSS 未变。两项为未配置的本地语音音频夹具，不能计为音频路径通过。此结果不覆盖第 674—677 篇；native-ui-654 在终态审计后已可复用。本阶段一直使用 native-ui-648，新夹具未修改旧清单。

## 明确剩余范围

语音页仍缺听写提示音及实际声音行为、按住／双击免提与“高级”单击快捷键展开、动态语音加载／错误／重试与服务能力映射、麦克风对语音会话和听写的共同接入及设备加载／错误、屏幕上下文启用引导、词典完整 Enter／鼠标／移除焦点生命周期、录音选择恢复与全部操作状态、所有材料／动效／窄屏变体及前台／VoiceOver 验收。本轮没有新增只显示却无实际功能的提示音开关，也不把现有设备端语言选择等同于参考账户语音语言。

真实麦克风、跨应用输入、实际用户 API、macOS 14 实机和全部逐页双端验收继续待完成。完整范围仍是 21 个主页面／交互类别、26 个设置面及 29 项核心功能，完整配对 **0/47**。

## 冻结全量终态补充

2026-10-08，原工具 handle 67014 已返回 exit 0，状态文件终止时间为 22:17:43（Asia/Shanghai）。固定提交 `d7d487d45cd2589be83a2ccd813480391cd6a7dd` 的全量 Swift 为 **2,938 项、2 项跳过、0 失败，4,701.739 秒**；之后 IPC 冒烟也 exit 0，日志 `.cache/full-alignment-regression-677.log`。两项跳过仍因未配置本地语音音频夹具，不是已验证真实音频；离线语法冷启动恢复为 0。

终态重新核对 manifest 中原 79 个源夹具、172 个编译资源、测试执行文件、保存的 helper 及参考 CSS，SHA-256 全部一致（`.cache/full-alignment-regression-677-terminal-audit.json`）。不把后续已编辑的 Swift 源码描述为未变化；全量仅覆盖启动时冻结的第 677 篇构建，不覆盖第 678 篇及以后。没有新的 Rust 源码变化或全量 Rust 运行，不以旧 Rust 测试计作本轮新结果；完整页面／交互配对仍为 **0/47**。
