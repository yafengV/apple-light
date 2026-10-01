# 追加消息附件进入 Sources

本阶段对照本机 Codex 桌面客户端 `26.911.61220` 的公开静态资源：`local-conversation-summary-panel-sources-model-b3e4b91603b4.js` 收集首轮和运行中追加用户消息的附件，`local-conversation-sources-side-panel-tab-6ca81b3a21b9.js` 对附件显示“Attached to the conversation”。此前 ShipiOS 只从每轮初始 `runFiles`、`runImages` 收集来源，已送出的追加消息附件可能缺席。

Sources 现在也读取任务记录中的追加消息文件与图片，并按附件 ID 和初始附件去重。完整来源页分别显示文件和图片的预览入口及“已附加到会话”；摘要仍保留简洁的名称入口。追加图片进入同一预览图库，文件继续使用已有安全附件读取路径。

`TaskSummarySourceTests`、`TaskProvidedWebLinksTests` 与 `DesktopFeaturesTests` 共 34 项通过；`script/build_and_run.sh --build-app` 和严格深度签名通过。本阶段没有新构建的可交互工作区或参考 Codex 客户端双端验收，完整验收仍为 **0/45**。后续仍需核对附件区域的视觉、焦点、键盘与预览全流程。
