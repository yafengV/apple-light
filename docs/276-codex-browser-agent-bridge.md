# Codex Core 与内置浏览器的首条真实工具链

2026-09-27。Codex Core 的 `shipios_browser` 原生工具现可请求 macOS 应用打开 http/https 网页、列出当前任务的浏览器标签、读取指定标签的主文档可见文字。工具调用通过 Agent 私有 IPC 往返，不读取用户个人 Codex 浏览器资料。每个请求带任务及一次性请求 ID；其他任务不能冒领响应，中断/停止任务会取消待处理请求。

参考 OpenAI 当前[内置浏览器说明](https://help.openai.com/en/articles/20001277-using-the-built-in-browser-in-the-chatgpt-desktop-app)：Agent 可与用户查看同一网页，并在使用新网站时请求授权。ShipiOS 的规则现在实际参与 `open` 和 `read`：阻止规则拒绝操作，允许规则直接执行，询问规则在所属可见任务窗口显示拒绝、本次允许或始终允许的 sheet；无可见窗口或已有 sheet 时拒绝。手动地址栏浏览不受 Agent 规则影响。列出标签仅提供标签 ID 和主机名，未授权前不向模型暴露路径、查询参数或页面文字。

浏览器工具严格按任务 ID 查找主窗口与独立任务窗口的标签；后台任务打开网页时不改变前台任务，新增标签及右侧面板归属写入该任务布局。读取前、授权后、JavaScript 返回后都校验标签仍属原任务且网页未改变。单次读取最多返回 8000 个字符。请求和结果合并为会话中的一张工具卡，成功打开或读取的网页进入任务来源。

Agent 打开网页期间只允许主文档留在获准主机；跨主机重定向会取消并要求对新主机重新授权。用户手动浏览原有标签不使用这项临时限制。

验证包含：Rust 请求 ID/任务归属与取消测试、假模型真实 Codex Core 工具调用往返、真实 WebKit 页面读取和后台任务导航、阻止/允许规则、跨主机重定向、拒绝读取不泄露路径、时间线及来源测试。最终浏览器和时间线定向回归 56 项通过，`script/build_and_run.sh --build-app`、签名校验和 Agent IPC 冒烟通过。`script/test.sh` 的 Rust 格式、严格 Clippy 和全套 Rust 测试通过；Swift 全量回归已执行部分未见失败，但在既有 `GitHubPRTests.testChangedBranchDuringGenerationRejectsGeneratedTextBeforePublishing` 长时间无进展后中止，不能记为全量通过。当前电脑使用工具两次读取桌面状态超时，未完成 ShipiOS 与 Codex 的原生配对验收。

这只是浏览器 Agent 的首条能力链。页面点击与输入、截图交给模型、下载控制、WebMCP 站点工具、跨 frame 内容、Chrome 扩展和 CDP 尚未实现；sheet 的视觉、焦点、键盘及与当前 Codex Mac 的逐项原生配对也未完成。
