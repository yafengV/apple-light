# 浏览器 Agent 点击触发的下载

2026-09-27。Agent 点击已检查的网页控件时，网页可能经事件处理程序才产生下载，事先没有可交给 `download` 的静态链接。现在 `click` 在 WebKit 操作期间捕获同站产生的下载，返回 `download_id`，把记录归属到当前任务，之后可用 `download_status` 与 `cancel_download`。同一标签的 Agent 控件操作互斥，防止并发点击覆盖下载归属。

WebKit 下载回调继续核对下载源站、重定向和最终响应站点；一次 Agent 点击最多捕获一个下载，额外下载会取消。跨站网页导航由点击期间的网站边界拦截。普通用户点击后的下载仍走原流程，不绑定到 Agent 任务。

真实 WebKit 测试用主文档及单独授权的跨站 iframe 点击事件生成同站下载，验证文件内容、任务专属查询、持久化归属及跨站生成路径阻断；本阶段浏览器套件 61 项、任务时间线 3 项及 Rust 浏览器工具 5 项通过，新增 iframe 情形单独复测通过。`cargo fmt --check`、`script/build_and_run.sh --build-app`、签名校验和 IPC 冒烟通过。按钮仍须用户在所属窗口确认；由于当前 Mac 锁屏，按钮确认弹层和 Codex 双端页面交互尚未原生验收。Blob URL 生成的下载随后在[第 282 篇](282-browser-blob-downloads.md)补齐；完整配对验收面仍为 0/43。
