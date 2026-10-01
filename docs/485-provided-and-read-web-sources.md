# 用户提供与聊天读取的网页来源

本阶段对照本机 Codex 桌面客户端 `26.911.61220` 的公开静态资源 `local-conversation-external-resources-f7d8d35c5ed9.js` 和 `local-conversation-sources-side-panel-tab-6ca81b3a21b9.js`。参考来源模型从用户消息、运行中追加消息与工具读取收集网页链接，同一资源可同时有 `provided`、`read` 等活动；Sources 展示这些活动。此前 ShipiOS 只收集网页读取结果，用户提交的链接不会出现在来源中。

现在从每轮已提交的用户文本及已送出的追加消息提取 Markdown 链接、自动链接与正文 URL；代码块和行内代码中的示例 URL 不计入，非 HTTP(S) 地址也不计入。来源以忽略片段及非根路径末尾斜杠的 URL 身份合并，保留有意义的用户链接标题，并在完整 Sources 中分别标明“在会话中提供”和“聊天期间读取”。当一个链接同时由用户提供且被网页搜索打开时，它仍保留外部来源条目；只有单纯读取且与“已打开网页”重复的条目才折叠到网页搜索分组。

`TaskProvidedWebLinksTests`、`TaskSummarySourceTests`、`CodexWebSourceTests` 和 `DesktopFeaturesTests` 共 36 项通过；`script/build_and_run.sh --build-app` 与严格深度签名通过。原生窗口检查再次返回 Mac 锁屏，不能确认新包工作区可交互；参考客户端桌面访问也仍受限制。完整双端验收保持 **0/45**。

当前尚未覆盖参考来源模型中的插件资源 `created/updated` 活动、服务提供者图标和资源别名合并；这些以及实际展开、焦点与布局仍需继续对齐。
