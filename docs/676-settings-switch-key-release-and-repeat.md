# 设置开关的按键释放、取消与重复回调

日期：2026-10-08。接续第 675 篇，补齐共享开关的输入生命周期；不缩减全部 UI 交互及核心功能目标。

## 参考及证据边界

固定 Codex 26.930.51102 / build 13100 的实际 `gyi` 组件使用 `type=button`、`role=switch` 和点击回调，公开函数及校验过的树见[第 675 篇](675-settings-switch-focus-and-rtl.md)。补充核对官方 [Chromium HTMLButtonElement](https://chromium.googlesource.com/chromium/src/%2B/9b8b876833a6ed372718e44f90fbadfca6a0fced/third_party/blink/renderer/core/html/forms/html_button_element.cc) 及 [HTMLElement::HandleKeyboardActivation](https://chromium.googlesource.com/chromium/src/%2B/ccebd1fb24b76dc2594e66b6fbad6c1192107405/third_party/blink/renderer/core/html/html_element.cc)：Space 按下设置 active、keypress 防止页面滚动、松开且仍 active 时产生点击；Enter 在 keypress 阶段点击。按钮 blur 会清除未关联 label 的 active。

窗口失焦路径另由官方 [FocusController](https://chromium.googlesource.com/chromium/src/%2B/af3159f6b882f925733a6dae791cd2f075937e80/third_party/blink/renderer/core/page/focus_controller.cc) 核对：FocusHasChanged 在失去页面焦点时，对仍记录为 focused element 的元素分发 blur，再处理 window blur；这一过程会取消按钮的待松开激活。

本地保存的官方 HTMLElement 源码 SHA-256 为 `b3377de5ea84dff8e0b4d3dbdb230a1479fd5a0f772e3dad6ecc638e638d84a5`（`.cache/settings-switch-blink-element-676.cc`）。它是明确固定的上游源码补充，不声称该提交就是已安装 Codex 的 Chromium 提交，也未执行完整浏览器／Electron 事件循环。[W3C UI Events key 定义](https://www.w3.org/TR/uievents-key/#keys-whitespace) 将数字键盘 Enter 纳入同一 Enter 含义；原生 SwiftUI 的对应字符为 U+0003。全部修饰键、全局快捷键和真实 Codex 双端按键仍需验收。

## 复现与实现

旧开关将 Space／Return 均在 keyDown 立即切换。测试先修正了 Observation 多变量声明的编译错误，以及隐藏窗口没有实际焦点、直接调用响应器未进入 SwiftUI 事件分发的问题；这些夹具错误不计产品缺陷。最终使用可成为 key 的隐藏 NSWindow、真实 NSHostingView、原生 Tab 焦点和 `NSWindow.sendEvent` 分发其自身事件。有效旧实现基线 **2 项、4 条断言失败、1.752 秒**（`.cache/settings-switch-keyboard-before-windowevents-676.log`）：Enter 通过，Space 按下及长按期间已有一次写入。

Space 现在只记录按下，在合法松开时切换一次；重复事件不写值，但能在当前焦点上重新进入按下状态，失焦、禁用、移除或鼠标激活会取消等待。Return 和数字键盘 Enter 在按下及重复阶段激活，释放不重复写入；普通 Shift 组合保留按钮激活能力，Command／Control／Option 组合交给现有快捷键路径。保持现有绑定、辅助功能表示、焦点滚动和绘制。

初步修复后，隐藏窗口验证发现：窗口失活仍保留 SwiftUI 焦点目标，返回时旧 Space 松开会错误切换。`SettingsKeyReleaseCancellation` 是不接受命中、不参与辅助功能的被动 NSView，只监听所属窗口的失去 key／关闭和应用失活；取消等待，不移动焦点、不写设置。移除时清理通知和回调，其他窗口的通知不影响当前按键。它不取代 SwiftUI 开关或其值状态。

回车重复还复现了旧回调读取旧值：诊断中画面已 render true，原重复回调仍读取 false，向实际 true 再次写 true（`.cache/settings-switch-keyboard-repeat-diagnostic-676.log`）。标准 `@Bindable` 下亦复现，不能归因于夹具闭包绑定。现在使用保留的动作对象只存储本次渲染的最新 Binding；重复回调读取最新来源，禁用／卸载清除来源。没有另存一个乐观开关值；新增拒绝写入用例确认连续请求仍为 true／true，实际值与写入计数不变。诊断打印已移除。

## 验证

定向 **11 项、0 失败／跳过、5.297 秒**（`.cache/settings-switch-keyboard-latest-binding-676.log`）：实际 Space 按下／重复／松开、Return 按下／释放／重复、拒绝绑定、Tab／Shift-Tab 实际焦点往返、禁用／重新启用、移除／重建、保留同一响应器的窗口失活／返回、应用失活通知、跨窗口通知隔离及 Shift／Command 组合。

首轮扩大 **545 项、0 失败／跳过、173.553 秒**（`.cache/settings-switch-keyboard-expanded-final-676.log`）后继续核对边界。新增两项确认数字键盘 Enter 未激活，以及首次收到 Space 重复事件后松开未激活：**13 项、6 条断言失败、6.895 秒**（`.cache/settings-switch-keyboard-edge-before-676.log`）。补齐两条路径后，最终定向 **13 项、0 失败／跳过、6.194 秒**（`.cache/settings-switch-keyboard-edge-final-676.log`）；前一轮 545 项不能冒充覆盖此后的改动。

原生事件只在测试进程的隐藏窗口内分发，没有向系统或其他应用发送键盘输入。Return 重复用例允许事件循环和 SwiftUI 渲染推进；不声称覆盖同一同步栈零间隔连发所有事件。应用失活和另一窗口隔离用例使用本地通知，验证取消／过滤回调，不代替前台切换应用。早期 8 项仍有窗口取消／重复失败、10 项仍有重复失败的日志保留；后续通过不抹去诊断过程。

最终扩大 **547 项、0 失败／跳过、174.782 秒**，覆盖上述最终边界修复（`.cache/settings-switch-keyboard-expanded-final2-676.log`）。通过 `script/build_and_run.sh --app` 使用 native-ui-648 构建正式包并执行启动命令，exit 0（`.cache/settings-switch-keyboard-final-default-run-676.log`）；严格深度签名校验通过，正式 helper 与第 673 篇保存的测试 helper CDHash 相同（`.cache/settings-switch-keyboard-final-signature-676.log`、`.cache/settings-switch-keyboard-code-equivalence-676.json`）。正式包 IPC 与本地 Core RPC 冒烟均 exit 0（`.cache/settings-switch-keyboard-ipc-676.log`、`.cache/settings-switch-keyboard-core-676.log`），没有调用真实用户 API。本阶段没有 Rust 源码改动，不声称重跑 Rust 全套。

再次运行真实开发证书的两版 Mach-O 检查，主应用和 helper 的代码哈希变化、指定要求保持一致，且新版通过旧版要求验证；无身份／无效身份拒绝和显式临时签名检查通过（`.cache/development-signing-request-final-676.log`）。最终 CUA 仍报告 Mac 锁屏，工作区交互及本次重建是否再次出现文件夹授权提示未能前台复验；启动命令成功不等于交互验收。首次由旧临时签名切换到开发证书仍可能需要授权一次，详见[开发签名](658-stable-development-signing.md)。

第 673 篇冻结全量仍在原 handle 99495 运行，使用 native-ui-654；本阶段使用独立 native-ui-648，不覆盖它的执行文件、资源或已捕获夹具。运行中再次核对 76 个源夹具、169 个资源、执行文件、helper 和参考 CSS 一致；这不是全量终态，也不能冒充覆盖本阶段代码。

## 剩余范围

其他 HTML 按钮类控件的释放／重复生命周期、所有键盘与鼠标来源、系统实际激活／失活、焦点视觉与动效、macOS 14 实机、真实用户 API 及完整逐页双端交互继续待完成。范围仍为 21 个主页面／交互类别、26 个设置面和 29 项核心功能；完整配对 **0/47**。
