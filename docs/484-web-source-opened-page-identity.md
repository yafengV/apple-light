# 搜索来源只记录实际打开的网页

本阶段对照本机 Codex 桌面客户端 `26.911.61220` 的公开静态资源：`local-conversation-external-resources-f7d8d35c5ed9.js` 只把网页搜索中的 `openPage`、`findInPage` 作为已读取网页来源，并以忽略片段及非根路径末尾斜杠的 URL 身份合并；`local-conversation-summary-panel-sources-model-b3e4b91603b4.js` 把同时列于网页搜索“已打开网页”的普通读取来源去重。此前 ShipiOS 把普通搜索结果列表也当成来源，已打开网页还可能在外部链接与网页搜索两处重复。

现在只有实际打开或页内查找的目标网页会进入搜索来源，结果列表中未打开的候选链接不进入。目标网页可从匹配的结果取标题，否则使用域名。来源按规范化 URL 身份去重；同一网页的普通读取来源与网页搜索已打开记录重合时，只在网页搜索分组中显示。浏览器单独读取的其他链接仍显示为外部来源。

`CodexWebSourceTests`、`TaskSummarySourceTests` 和 `DesktopFeaturesTests` 共 32 项通过；`script/build_and_run.sh --build-app` 和严格深度签名通过。原生窗口接口再次确认 Mac 锁屏，不能验证新包工作区可交互；参考 Codex 客户端桌面访问仍受限制。完整双端逐页逐交互验收保持 **0/45**。

当前来源记录尚未携带参考客户端完整的 `provided/read/created/updated` 活动分类，也没有全部插件来源的资源别名合并；本阶段纠正的是网页搜索的来源资格和已打开网页的重复显示。
