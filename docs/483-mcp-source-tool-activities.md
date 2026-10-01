# Sources 中的 MCP 工具活动

本阶段对照本机 Codex 桌面客户端 `26.911.61220` 的公开静态资源 `local-conversation-summary-panel-sources-model-b3e4b91603b4.js` 与 `local-conversation-sources-side-panel-tab-6ca81b3a21b9.js`。参考界面把 MCP 来源按服务或应用聚合，再按工具活动显示使用次数；单次调用可直接展开，多次调用先展开工具组，再逐次呈现内容。此前 ShipiOS 的 Sources 只显示服务名。

现在任务各回合的 MCP 调用按稳定服务 ID 合并，服务内按工具名和原调用顺序分组。Sources 显示每个工具的次数；单次调用可展开参数和结果，多次调用可展开后逐次查看状态、参数和结果。结果沿用现有 `MCPResultView`，保留文本、图片、音频和资源的呈现能力；来源搜索支持服务名与工具名。任务摘要仍以服务为一条来源，避免大量调用挤占摘要。

`TaskSummarySourceTests`、`MCPResultDocumentTests` 与 `DesktopFeaturesTests` 整组 33 项在允许系统媒体服务的环境通过；正式应用构建及严格深度签名通过。首次受限运行只有音频解码用例因系统媒体服务不可用失败，该用例单独在允许媒体服务时通过，随后整组 33 项通过。前台窗口与 Codex 参考客户端的逐项交互尚未配对；完整双端验收仍为 **0/45**。

参考端会结合插件上下文生成更友好的工具名称与图标，ShipiOS 当前使用调用记录中的服务名和工具名；精确文字、视觉密度、展开焦点及键盘行为仍需在可交互的双端窗口验收。
