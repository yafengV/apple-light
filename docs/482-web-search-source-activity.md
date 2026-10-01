# Sources 网页搜索活动

本阶段核对本机安装的 Codex 桌面客户端 `26.911.61220` 的公开静态资源：`local-conversation-summary-panel-sources-model-b3e4b91603b4.js` 汇总搜索次数、去重搜索词与已打开链接，`local-conversation-sources-side-panel-tab-6ca81b3a21b9.js` 在 Sources 中分别以可展开的“搜索 N 次”“打开 N 个网页”展示。此前 ShipiOS 只有不可展开的“网页搜索”标签。

现在每次完成的 Core 网页搜索把搜索词或实际打开/页内查找的网页存入工具调用记录；Sources 跨回合汇总重复搜索的总次数、唯一搜索词和唯一打开链接，并提供可点击的网页入口。旧任务没有结构化元数据时，从原有时间线文案恢复可辨认的搜索词和网页。来源搜索框也能按搜索词、网页标题与 URL 找到该组。

定向 `CodexWebSourceTests`、`TaskSummarySourceTests` 与 `DesktopFeaturesTests` 共 30 项通过；`script/build_and_run.sh --build-app` 与严格深度签名检查通过。前台原生窗口检查再次返回 Mac 锁屏，参考 Codex 客户端的桌面控制访问仍受限制，因此本次没有新构建的可交互工作区证明，也没有完成双端逐项验收。

仍需对照参考客户端实际页面的展开、焦点与链接打开行为；搜索结果来源和“已打开网页”在某些任务中可能重复显示，因为现有 `codex_web_sources` 记录没有足够的来源活动类型可供精确归并。完整验收保持 **0/45**，其中 45 是验收类别数，不代表 45 个已知缺陷。
