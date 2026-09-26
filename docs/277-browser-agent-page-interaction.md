# 浏览器 Agent 的页面控件检查与操作

对齐依据：[OpenAI 内置浏览器说明](https://help.openai.com/en/articles/20001277-using-the-built-in-browser-in-the-chatgpt-desktop-app)描述了 Agent 与用户查看同一网页、跨标签工作和新网站授权。站点工具另见[官方说明](https://help.openai.com/en/articles/20001423-using-site-tools-in-the-chatgpt-desktop-app)，本阶段尚未实现 WebMCP。

2026-09-27。`shipios_browser` 在打开、列出和读取网页之外，新增 `inspect`、`click`、`fill`。`inspect` 从当前任务的已授权 WebKit 标签列出最多 50 个可见链接、按钮与输入控件，给出页面内短期有效的句柄；`click` 激活句柄，`fill` 可填写普通文本框、文本区域、下拉选项与可编辑区域。密码、文件等敏感或不支持的输入类型不能由 Agent 填写。句柄保存在隔离 JavaScript 世界中，页面导航、重新载入或再次检查后旧句柄失效。浏览器工具输出标记为外部网页内容，避免被误当作可信的应用内部上下文。

网站访问规则覆盖检查与操作。跨网站链接要求 Agent 用 `open` 单独打开并取得该网站授权；新窗口链接也须改用 `open`。按钮、提交控件及 `role=button` 在所属可见任务窗口再次显示操作确认；没有可见窗口或已有 sheet 时拒绝。Agent 操作期间主文档跨网站导航与弹出窗口会被拦截。回合停止、断流或新回合开始使旧请求令牌失效，等待中的授权 sheet 会自行关闭，旧请求不能继续操作；会话里未完成的浏览器工具卡会结束为取消或失败。

真实 WebKit 回归覆盖任务归属、网站阻止规则、填写值和 input 事件、同站点击导航、过期与畸形句柄、密码框拒绝、无可见窗口的按钮拒绝、跨站链接/重定向及弹出链接拒绝、输出大小上限和无效回合令牌；浏览器及时间线最终 59 项通过。假模型真实 Codex Core 回合验证 `fill` 的标签 ID、句柄和文字能够往返 Agent 与宿主。Rust 严格 Clippy、全套相关测试、`script/build_and_run.sh --build-app`、签名校验及 IPC 冒烟通过。Swift 扩大回归执行到第 917 项时均无失败，但在既有终端关闭/重启测试停滞后中止；拆分尾段再次在既有工作树用例停滞，不能记为全量通过。两处停滞用例和前一轮 GitHub PR 停滞用例分别单独运行均通过。

后续 [第 278 篇](278-browser-agent-screenshot.md) 补上当前视口截图回传模型。跨 frame 控件、下载操作、站点工具、CDP、敏感操作的完整分类审批，以及当前 Codex Mac 与 ShipiOS 的逐页原生视觉、焦点和键盘配对仍缺。电脑使用工具本轮读取桌面状态超时，不能将自动化测试计为原生验收。
