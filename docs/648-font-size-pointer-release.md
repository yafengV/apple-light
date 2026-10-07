# 字号箭头方向与松手保存

日期：2026-10-07。接续第 647 篇；范围仍为 21 类主窗口、26 类设置与 29 项核心要求，完整双端配对 **0/47**。

## 参考行为与失败证据

本机公开参考版本仍为 26.930.51102 / build 13100。已核对的设置资源 SHA-256 为 `91ef510e7631785df4c62c25f3b9018a0ca3c15ce3fa1b208f3cf8394abdf535`。其中 `sc` / `cc` 对界面/代码字号记录按下时的输入文字；松手时文字若变化，立即执行同一个校验/保存函数，并清除按下快照。文字不变时不规范化，也不保存另一个未提交的键盘草稿。

`script/extract_appearance_font_size_pointer_reference.cjs` 在受控 VM 中直接执行这两个公开组件的回调，不启动参考应用。新增夹具 `appearance_font_size_pointer_reference_648.json` 保存 18 组结果，包括增减、上下界、空值、非规范文字、不变输入和重复松手。夹具只证明这些回调语义，不代替参考端真实鼠标操作。

原控件 `mouseUp` 只停止长按计时器，值到失焦才保存。首次测试草稿缺少 AppKit `with:` 标签，日志 `.cache/font-size-pointer-before-648.log`，编译失败，不计运行验证。修正测试标签、保持生产代码不变后，隐藏原生窗口的鼠标松手测试 **1 项、3 条失败、exit 1**（`.cache/font-size-pointer-baseline-648.log`）：松手时仍是旧值，写入次数仍为零。

## 实现与边界

- 原生控件在箭头按下时保存实际输入文字；释放时先停止重复计时，再仅对有变化的文字走现有提交/落盘流程。
- 前台恢复后又实际发现视觉上箭头令代码字号 12→11；已恢复原值。此前合成事件测试按未翻转坐标构造位置，未发现 NSTextField 的翻转方向。修正测试为实际视觉上下位置后，旧方向逻辑 **1 项、8 条失败、exit 1**（`.cache/font-size-pointer-direction-before-648.log`）。现绘制、点击与拖动统一按 `isFlipped` 解析，上方增加、下方减少；不改变键盘 Up/Down 语义。
- 保留 Enter / 失焦保存、上下箭头及滚轮的键盘草稿行为；不把每次长按重复都写盘。
- 不变的上界文字保留原草稿，后续失焦仍正常校验/保存；重复释放不再次写入。
- 取消长按、禁用、移除和析构清理快照。原控件/Coordinator 的有效性、窗口、模态及输入法组合保护继续适用。
- 拒绝写入时读取真实已保存值，恢复编辑器并保留焦点；再次操作可重试。

新测试先将“移除聚焦控件”也理解为不得保存，扩大集出现 **25 项、2 条失败**（`.cache/font-size-pointer-associated-648.log`）。实际 AppKit 在控件还属于原窗口时正常结束编辑，失焦保存一次；这应保留。现单列验证正常失焦一次、随后迟到的旧松手不再写入，没有为满足错误假设阻止失焦。

## 验证

松手保存修复阶段的字号关联 **26 项、0 失败/跳过、17.502 秒、exit 0**（`.cache/font-size-pointer-associated2-648.log`），包含九项新增回归和十七项既有字号用例。新测试覆盖 18 组真实参考回调结果、原生按下/释放双方向与两类字号、长按释放、上界未改变文字、禁用/取消/模态、正常移除后迟到释放、拒绝后重试以及实际设置行落盘/加载后的其他中文草稿保持。

上述原生事件验证在隐藏 NSWindow 中构造 NSEvent 并直接调用控件的 `mouseDown` / `mouseUp`，不等于前台通过系统事件投递的用户操作；参考回调夹具再次生成后逐字节一致。

首次扩大关联 **203 项、1 个 unexpected failure、74.827 秒、exit 1**（`.cache/font-size-pointer-expanded-648.log`）：仍为 `testPartialResultsKeepAWorkingSearchAlive` 的 400 毫秒超时。九项新增字号用例及其余外观/设置范围通过，但不能将扩大集记为通过；第 647 篇已读响应修复不能解释全部间歇失败。

在发现视觉箭头反向前，正式 helper 的外观/设置范围 **159 项、0 失败/跳过、69.424 秒、exit 0**（`.cache/font-size-pointer-formal-ui-648.log`），正式构建/签名/IPC/Core 亦通过。这些是中间版本结果，不代替下述最终验证。

修正视觉方向后，最终 **159 项、0 失败/跳过、70.625 秒、exit 0**（`.cache/font-size-pointer-direction-final-ui-648.log`）。该范围为 Appearance、SettingsNavigationTests、ThemeCardReferenceTests、ShipiOSResourceBundleTests、SettingsReturnFocusTests；所有前后集合重叠，不累加。最终构建/启动 exit 0（`.cache/font-size-pointer-formal-final-run-648.log`）；随后两次标准脚本重启分别见 `.cache/font-size-pointer-restart-648.log` / `.cache/font-size-pointer-unicode-restart-648.log`。最终严格签名与 IPC/Core 冒烟均 exit 0，日志 `.cache/font-size-pointer-signature-final-648.log` / `.cache/font-size-pointer-ipc-final-648.log` / `.cache/font-size-pointer-core-rpc-final-648.log`。最终包 helper SHA-256 保持 `380bec2aac119df2c9755850f1aa6150dd14cb9403a2eb8d42eff39e7f54ae9b`。没有 Rust 源码变更，不新增 Rust 全套复测结论。

## 前台与完整回归

第 647 篇已提交并推送 `fa27fc962c5eb53e8829d242b81a4279c2d9cb59`。该提交的固定全量于 2026-10-07 18:14（本地时间）启动：runner handle `76513`，清单 `.cache/full-alignment-regression-647-manifest.json`，日志/状态分别为同前缀 `.log` / `-status.json`。冻结测试可执行文件、55 个既有夹具及 150 个应用/测试资源文件；本阶段使用独立 `.cache/native-ui-648`，新增夹具不修改冻结文件。该全量不覆盖本阶段的新字号修复；终态前不记为通过。

本轮初期 CUA 明确返回 Mac locked，之后前台访问恢复：中间正式包默认 `other` 工作区可交互，⌘, 在同一 `ID: main` 中打开设置；外观默认只显示当前有效深色色板，高级折叠。已实操展开、临时双模式、折叠后保留两张视觉卡片及折叠时重置回默认单模式，均未改变主题选择。这里的前台证据属于中间版本；最终包复验结果单列如下。

最终方向修复包已重复实际验收：

1. 默认 `other` 工作区可交互，无持续恢复 loading；⌘, 同窗口进入设置，外观默认单模式、高级折叠。
2. 代码字号初值 12，聚焦后实际点击视觉上箭头，松手即为 13，同时出现重置入口、原输入器按提交值重建。没有借用失焦操作证明保存。
3. 标准脚本重启后，代码字号仍为 13。首次逐字输入流程仅确认到数字 `648`，不据此证明完整中文恢复；改用粘贴并先在原输入器确认 `字号验收648🙂` 后再次重启，完整中文/Emoji 草稿保留。
4. 实际点击视觉下箭头，松手即回到 12，重置入口消失；界面字号仍 14，原系统模式及颜色/字体保持。
5. 最终包再次验证临时双模式、折叠移除高级项、折叠中重置返回单模式；Esc 回到原任务且焦点属于任务输入器。实际再输入 ASCII 后，文字仍进入原草稿；验收草稿已清空，恢复原空输入。

没有发送模型消息、修改 API 服务或读取个人 Codex 配置。以上是 ShipiOS 单端实操，仍不等于完整双端页面配对。

字体平滑/Dock/VoiceOver、全部字号鼠标/键盘组合、整页布局/颜色、文件搜索间歇失败及其余 47 类完整配对仍待完成。目标未完成。
