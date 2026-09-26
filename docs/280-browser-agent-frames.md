# 浏览器 Agent 的 iframe 控件

2026-09-27。`shipios_browser.inspect` 现在可检查普通 HTTP/HTTPS iframe 中的可见控件。WebKit 将脚本注入每个 frame，并用 [`WKScriptMessage.frameInfo`](https://developer.apple.com/documentation/webkit/wkscriptmessage/frameinfo) 记录来源；调用 JavaScript 时指定相应的 [`WKFrameInfo`](https://developer.apple.com/documentation/webkit/wkframeinfo)。每次文档加载生成新 frame token，检查和操作时重新核对 token、网址与本次扫描 ID，因此 iframe 导航后旧句柄失效。

跨站 iframe 需单独取得网站权限；拒绝时 `inspect` 不返回该 frame 的控件或网址。点击、填写和下载前再次核对权限、任务归属及当前 frame；链接只允许跳转或下载到该 frame 已授权的同一网站。按钮仍需所属窗口确认，确认页显示 iframe 网站。

真实 WebKit 测试覆盖同站 iframe 检查与填写、iframe 导航和主页面导航后的句柄失效、跨站 iframe 拒绝/授权/撤销、授权 iframe 的下载；浏览器套件 60 项、任务时间线 3 项通过。`script/build_and_run.sh --build-app` 构建与签名、`codesign --verify --deep --strict` 和真实 IPC 冒烟通过。普通 HTTP/HTTPS 嵌入页已覆盖；`about:blank`、`srcdoc`、沙箱 iframe、动态按钮生成下载、完整原生交互与 Codex 双端逐页配对仍待单独验收。当前 Mac 锁屏，不能将这些自动化结果记为可见配对通过；43 个完整配对验收面仍为 0。
