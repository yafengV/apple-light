# 会话滚动跟随与查找导航

2026-09-17。对应审计 D06、E03。当前完成实现和状态测试，原生验收被 Mac 锁屏阻止，**尚不能认定与 Codex 一致或完成实机验证**。

## 当前修改

- 将会话时间线拆为 ConversationTimelineView，移除“只要回合数量变化就强制滚到底部”的处理。
- 区分跟随最新内容与阅读历史。内容增长、Markdown 异步排版和窗口尺寸变化不直接解释为用户滚动；检测到用户上滚时暂停跟随。
- 离开底部后显示返回底部按钮，阅读期间有新内容时增加提示；主动返回底部后恢复跟随。当前底部容差为 40 点，这是实现参数，尚无当前 Codex 实机证据证明该值一致。
- 查找定位先暂停跟随，防止流式内容立即把查找位置拉走。任务切换重建该任务的滚动状态；设置打开/返回仍保留挂载的会话视图。
- 添加“上一个匹配”按钮和 ⌘⇧G，保留 ⌘G 下一项；首尾循环、无结果禁用、单个结果可再次定位。显示当前匹配序号。
- 仍按回合匹配查找结果，不是每个文本出现位置的独立匹配；精确文本高亮和长回复内的字符定位仍待补齐。

快捷键依据：[官方 Commands](https://learn.chatgpt.com/docs/reference/commands#keyboard-shortcuts)。官方页面列出上下匹配快捷键，但没有说明精确滚动阈值和自动跟随策略；这些细节继续列为待配对核验。

## 原生桥接范围

应用最低支持 macOS 14，而 SwiftUI onScrollGeometryChange / onScrollPhaseChange 从 macOS 15 开始可用（已核对本机 SDK 声明）。因此以一个透明、不可命中的 NSViewRepresentable 观察现有 NSScrollView，不替换 SwiftUI 的文本选择和 LazyVStack。

观察 clip bounds、内容 frame 和 live-scroll 起止通知。SwiftUI 状态更新延后到主队列，避免在布局过程中修改状态；卸载时删除通知、恢复通知开关并丢弃已排队的旧回调。平台依据：[boundsDidChangeNotification](https://developer.apple.com/documentation/appkit/nsview/boundsdidchangenotification)、[willStartLiveScrollNotification](https://developer.apple.com/documentation/appkit/nsscrollview/willstartlivescrollnotification)。

## 测试与待验收

新增 7 项测试，覆盖首次及延迟排版跟随、用户手势优先、滚动条/键盘无 live-scroll 通知时的暂停、窗口尺寸变化、查找与新内容、匹配循环和单结果重复定位。完整回归通过 110 项 Swift、12 项 Rust、fmt/Clippy 和真实 IPC：`.cache/conversation-scroll-full-tests.log`。最后追加“查找跳转前的迟到布局不能恢复跟随”修复及测试后，滚动、导航、快捷键共 15 项定向测试通过：`.cache/conversation-scroll-final-tests.log`。

已准备独立长会话测试目录 `/tmp/shipios-scroll-20260917`，包含 8 轮带 HISTORY 标记的本地静态回复、一条短会话，以及输入草稿 `scroll-stream`。测试服务 `apps/macos/Tests/Fixtures/model_server.py` 对该提示返回 120 段本地 SSE 文本，间隔 350 ms，不调用外部模型、无需密钥。运行服务后用实际端口更新该测试目录的 model.json；不得修改原用户服务配置。

原生待验收顺序：

1. 长会话首次进入位于底部，短会话不显示返回底部。
2. 发送本地 scroll-stream，观察流式段落和异步排版持续跟随。
3. 上滚查看 HISTORY 标记，新段落到达后阅读位置不被拉回，返回按钮显示新内容提示。
4. 点击返回底部，核验最新段落并恢复跟随。
5. 流式生成时查找、⌘G、⌘⇧G，核验焦点、循环与阅读位置。
6. 切换短/长任务、打开设置再返回、调整终端/右侧面板，核验滚动位置和焦点。
7. 复验段落内文本选择、代码块横向滚动，不被外层观察器干扰。

本轮首次 CUA 实测返回“Mac is locked and automatic unlock could not unlock it”，已经请求用户手动解锁。未尝试绕过锁屏。临时测试服务已停止，应用重新指向原开发工作区；锁屏下未重新验证其可见状态。构建成功、进程存在和状态测试通过均不能替代上述原生验收。

后续逐处索引、高亮和字形定位实现见 [第 27 篇](27-conversation-find-occurrences.md)，原生验收仍未完成。
