# 词典草稿、保存与原生焦点交互

日期：2026-10-08。接续第 677 篇语音页布局，范围保持全部 47 类页面／交互和 29 类核心功能；本篇不代表语音页或整个应用已经完成配对验收。

## 参考与复现

固定公开客户端 26.930.51102／build 13100 的 `voice-settings-1053b1128b33.js`，SHA-256 `dcac6c84dc913e502511a3c408178dad8266acbd53fe463c312c7dcb5757055f`。新增 `script/extract_voice_dictionary_interactions.cjs`，实际执行 `kn`、`An`、`jn`、`Mn`、`Nn` 的事件回调，使用本地 hooks／存储／动画帧夹具。输出 `voice_dictionary_reference_678.json`；重新生成结果逐字节一致。跨 VM 的异步存储续执行最初未完全排空，改为等待事件循环后提取成功；这不是客户端失败。

参考回调证明：本地草稿与已保存词典分离；Enter 在当前项后插入空项并跳过一次 blur 保存；真实 blur 执行 trim、过滤空项并清除草稿；添加／删除的 mouseDown 调用 preventDefault；删除使用当前索引和草稿；空列表显示一个空输入；重复词条不去重。这个夹具没有执行浏览器 DOM 的真实焦点时序、账户或设备操作，不将其当作前台双端交互验收。

旧 ShipiOS 使用实际原生输入框复现 Enter 提前保存：1 项测试、1 条断言失败，词典已变成 `中文草稿/Last`，参考此时仍保存 `First/Last`（`.cache/voice-dictionary-before3-678.log`）。前两次夹具分别因复杂表达式和对非 optional 标识使用 optional chaining 未编译，不计为产品失败。

## 实现

从 `VoiceSettingsView` 抽出 `VoiceDictionarySettingsCard`，仍在主窗口的语音设置页中。草稿独立保存，字段按参考使用索引身份，不再在每次失焦后重新生成全部 UUID。Enter 保留原字段与未提交内容，聚焦下一空项，仅跳过这一次焦点切换的保存；之后真实失焦才保存。删除以最新草稿和索引执行，保留仍存在的输入框，当前索引被删除时更新同一编辑器的显示内容；删除全部项后回到禁用删除按钮的空输入。程序直接卸载页面而未发生 blur 时，不额外写入草稿。

输入框使用参考的四个示例 placeholder 和带序号的辅助功能标签。`VoicePreferences` 的词典 trim 对齐实际 JavaScript 回调：包括 FEFF，保留 NEL、蒙古文元音分隔符和零宽空格，保留重复项与内部空格。八组实际参考输入／输出与 Swift 结果比对通过。

新增局部 `VoiceDictionaryActionButton` 原生按钮桥接：鼠标按下保留文本编辑焦点与选区，松开后按命中位置执行；键盘保持 Tab 可达，Space 松开激活，Enter／数字键盘 Enter 激活，失焦／窗口或应用失活取消等待。支持标准原生激活和辅助功能 press，遵循父级禁用状态与 RTL 环境，并接入共享设置焦点滚动；迟到的滚动回调必须仍属于当前响应器。输入框同时接入已有焦点滚动机制。没有全局事件注入或新的系统权限请求。

## 验证与边界

原生测试验证实际语音页面及抽出的同一组件，包括 Enter、真实 blur、磁盘恢复、索引删除后的编辑器／选区保留、空白／重复词条、禁用回退、Tab 与 Space、按下保留编辑、移出后松开取消、窗口失活、标准激活、RTL 与离屏焦点显示。

早期新增测试把 AppKit 子视图枚举顺序当成视觉顺序，以及向 `hitTest` 传入了自身坐标而非父坐标，已修正；这些结果不证明产品行顺序或命中缺陷。隐藏窗口的 `sendEvent` 指针路由未能触发删除，故最终指针测试明确限定在命中后的自有原生控件边界，不能声称前台整窗点击通过。离屏夹具还需清除安装内容时自动选中的首个 key view，并用实际可见高度判断空矩形；保留了聚焦后整行可见与迟到回调拒绝断言。

中间扩大回归 586 项、0 失败／跳过、186.160 秒（`.cache/voice-dictionary-expanded-678.log`），随后三项补查暴露标准激活、方向传递及焦点通知缺口；初版离屏起始断言另属夹具问题。此中间结果不冒充后续原生桥接的最终验证。一次构建期间继续编辑输入文件，被 Swift 拒绝（`.cache/voice-dictionary-focused7-678.log`）；其结果作废，之后等待源码稳定再完整验证。

最终专项 **29 项、0 失败／跳过、15.829 秒**（`.cache/voice-dictionary-focused-final4-678.log`），覆盖最终桥接和父级禁用修复。实际语音页隐藏窗口渲染已检查（`.cache/voice-dictionary-full-final-678.png`）；原生按钮补查单独 3 项通过，与 29 项重叠，不累加。最终扩大 **589 项、0 失败／跳过、188.609 秒**（`.cache/voice-dictionary-expanded-final-678.log`），覆盖最终源码的设置、外观、恢复、快捷键和语音／词典路径；与专项重叠，不累加。

标准 `script/build_and_run.sh --app` 使用 native-ui-654 完成正式构建与启动命令，exit 0（`.cache/voice-dictionary-final-default-run-678.log`）。主应用代码哈希变化，主应用／helper 指定要求与重建前相同，均使用 Apple Development，旧要求验证与严格深度校验通过；正式 helper 与测试使用的第 677 篇保存 helper 代码哈希一致（`.cache/voice-dictionary-code-equivalence-678.json`）。正式包 IPC／本地 Core RPC 冒烟均 exit 0（`.cache/voice-dictionary-ipc-678.log`、`.cache/voice-dictionary-core-678.log`），未调用用户真实 API。本篇没有 Rust 源码改动，不声称重新运行 Rust 全套。

正式启动后 CUA 仍明确报告 Mac 锁屏，不能完成前台工作区可交互、真实点击／滚动／重启及重复文件夹授权提示验收。没有将启动命令或隐藏窗口验证描述为前台通过。

第 677 篇冻结全量仍使用原 native-ui-648 执行文件、helper、79 个源夹具、172 个打包资源及参考 CSS；本篇使用独立 native-ui-654 缓存，冻结输入核对未变。该全量不覆盖本篇，运行状态不计为通过。

词典仍需前台整窗指针／焦点时序、中文 IME 和修饰键组合、全部辅助功能、精确输入框／按钮视觉与滚动位置，以及 Codex／ShipiOS 配对验收。语音页其余提示音、高级热键展开、动态服务／设备状态、共用麦克风、屏幕启用引导、录音恢复和菜单样式继续保持未完成。完整配对仍为 **0/47**。
