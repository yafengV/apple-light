# 浏览器 Agent 下载与进度控制

依据：[OpenAI 内置浏览器说明](https://help.openai.com/en/articles/20001277-using-the-built-in-browser-in-the-chatgpt-desktop-app)说明 Agent 可在同一任务中发起下载，保存时可能请求用户选择位置。WebKit 的 [WKDownloadDelegate](https://developer.apple.com/documentation/webkit/wkdownloaddelegate)提供重定向、目标位置、完成与失败回调。

2026-09-27。`shipios_browser` 新增 `download`、`download_status` 和 `cancel_download`。Agent 先在所属任务已授权的浏览器标签中用 `inspect` 取得链接句柄，再以该句柄开始下载；不能把任意网址或其他任务的标签直接交给下载工具。下载仍沿用浏览器设置的保存文件夹与“每次询问”选项，进度、完成、失败和取消写入现有下载列表。下载 ID 与任务绑定，只有所属任务的 Agent 可查询或取消，完成后可得到确实存在的本地文件路径。

下载链接与原网页必须同站。WebKit 下载发生跨站重定向时在发送重定向请求前取消；最终响应的站点也会再次核对，避免把跨站内容保存为已授权下载。页面点击触发的普通用户下载仍沿用原流程。

真实 WebKit 回归覆盖授权拒绝、同站文件下载、记录持久化、跨任务查询阻断、跨站链接和重定向阻断、慢速下载取消；浏览器套件 58 项通过。假模型 Codex Core 回合验证 `download` 的任务标签与短期句柄能往返 Agent 和宿主。当前只支持已检查的同站链接；按钮生成、跨 frame 链接、浏览器扩展下载和当前 Codex Mac 的逐页原生视觉及交互配对仍待完成。桌面工具本轮明确报告 Mac 锁定，因此 43 个完整配对验收面仍为 0。
