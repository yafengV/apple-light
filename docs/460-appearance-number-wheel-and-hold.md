# 外观字号输入的滚轮与长按

外观页界面／代码字号的数字输入原先仅能单击箭头或按上下键。现在焦点在字段内时，滚轮向上／下各步进一次；未聚焦时交给外层滚动。按住箭头先改一次草稿，500 毫秒后每 50 毫秒继续步进；拖动到另一半会切换方向。鼠标松开、字段失焦／停用、卸载或离开窗口时停止重复。滚轮和长按仍只改草稿，回车或失焦才写入设置。

参考依据是本机缓存的 Codex 外观页资源 `general-settings-ed7ca2006cd3.js` 中的 HTML 数字输入，以及 Chromium [spin button 的滚轮、按住和指针捕获处理](https://raw.githubusercontent.com/chromium/chromium/main/third_party/blink/renderer/core/html/forms/spin_button_element.cc)、[聚焦时才响应滚轮](https://raw.githubusercontent.com/chromium/chromium/main/third_party/blink/renderer/core/html/forms/text_field_input_type.cc)和 [macOS 自动重复默认时序](https://raw.githubusercontent.com/chromium/chromium/main/third_party/blink/renderer/core/scroll/scrollbar_theme_mac.cc)。当前用户系统可能覆盖 Chromium 的默认时序，仍需双端前台实测。

字号测试共 17 项通过，包括新增的滚轮、长按和失焦取消测试。受限环境内离线 WebKit 样例启动卡住，使用系统权限复跑整组通过。`script/build_and_run.sh --verify` 完成正式构建、签名和进程启动，严格深度签名检查通过。随后隔离启动的应用在 CoreGraphics 窗口列表中显示“新任务”主窗口，说明辅助功能返回零窗口不能证明窗口未创建；见[第 461 篇](461-main-window-observation.md)。桌面控制接口仍超时，无法确认可交互工作区，也没有完成 Codex 与 ShipiOS 的实际指针、滚轮、焦点和字体视觉配对；完整验收保持 **0/45**。
