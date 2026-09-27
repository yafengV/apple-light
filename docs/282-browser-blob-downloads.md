# 浏览器 Blob 下载

2026-09-27。[W3C File API](https://www.w3.org/TR/FileAPI/)说明 Blob URL 携带创建环境的来源，可用于网页生成文件下载。[WebKit 导航策略](https://developer.apple.com/documentation/webkit/wknavigationactionpolicy/download)允许把带下载意图的导航交给 `WKDownload`。ShipiOS 只在 WebKit 标记下载、Blob URL 为 HTTP/HTTPS 来源、且发起 frame 与 Blob 来源同源时允许此路径；地址栏仍不接受 `blob:` 导航。Agent 操作另须符合已授权的 frame 网站，并延续单次点击一个下载、任务归属和进度查询边界。

真实 WebKit 测试覆盖主文档 Agent 点击生成 Blob、普通网页点击下载、单独授权的跨站 iframe 生成 Blob；验证保存内容、原页面留存和 Agent 任务归属。浏览器套件 62 项通过。当前 Mac 锁屏，保存面板、按钮确认弹层及 Codex 双端逐页交互尚未原生配对；完整配对验收面仍为 0/43。
