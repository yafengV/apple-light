# 子任务冷发现、概览分类与近期排序

日期：2026-10-07。接续第 638 篇。47 类页面及 29 项核心要求不缩减，完整 Codex 双端配对仍 **0/47**。

## 当前参考与差异

重新读取安装包公开资源：Codex 26.930.51102 / build 13100，local-conversation-subagents-panel-tab-797735e5898b.js，7,668 字节，SHA-256 d87313d9ce52d9e65f0d5886c84648b6f59ea8af806a176214d5b8d16a2b4c19，副本 `.cache/subagent-overview-current-reference-639.js`。它从当前 app-primary-c0280d43ce72.js 导入 bet 排序：按 recencyAtMs 降序，活动包含 waiting，完成为 done；活动/完成首次显示 4/10 项。等待有独立计数和标签。Det 的已发现、无活动运行时路径为 done；错误/中断仍按上阶段规则隐藏。只读公开资源，不访问 Codex 个人配置或会话；静态研究不替代双端前台验收。

旧 Swift 概览将 notLoaded 计入活动，专项 1 项、2 条断言失败，日志 `.cache/cold-overview-ui-before-639.log`。实际 Core 冷恢复只给出 notLoaded 和空元数据，增强既有测试后旧实现 1 项失败，日志 `.cache/cold-overview-native-before-639.log`。这会依赖旧界面快照，无法可靠呈现未记录在快照中的线程终态、名称和模型。

## 实现

- DescendantSource 从同一任务私有 ThreadStore 读取冷线程元数据及持久历史，恢复已记录的父子身份、名称/角色、层级、模型/推理、最近终态及摘要。始终 loaded:false，不通过查询启动子线程或提交模型请求。未知字段保持未知，不从个人配置推断。
- 最新回合边界优先：完成/失败使用 TurnComplete；显式中断使用 TurnAborted；未完成的冷历史保持 notLoaded，不假装恢复了活进程。明确恢复后的空闲队列沿用第 637 篇的 interrupted 处理；原生关闭图仍覆盖为 shutdown。
- 独立概览状态映射 waiting/active/done/hidden：pendingInit 等待、running 活动、completed/notLoaded 完成，failed/interrupted/shutdown 隐藏。工作/停止/输入权限仍使用原始状态及 loaded，概览分类不会启用冷线程输入。
- 传递真实产品 recencyAtMs，列表及摘要共用降序投影；同时间/旧数据保留原顺序，轮询 observedAtMs 不参与排序。持久化及旧 wire 缺字段兼容，负值拒收。等待有独立计数，冷完成条目不再回退显示“未运行”。
- 主窗口和独立任务窗口共用的概览在打开/恢复时只读发现；缺少界面子记录也可重新连接原根并重建概览，不先加载子线程。失败在当前面板提供重新加载；取消及根变更不投递旧错误。
- 点击记录为关闭的子任务始终是只读历史导航，即使连接期间原生发现已纠正旧状态也不隐式加载；实际关闭仍以 Core 持久图为准。

## 自动验证及修正

真实 Core 四项冷历史/身份/重新加载专项最终通过，日志 `.cache/cold-overview-native-final2-639.log`。新增用例包含完成、HTTP 400、实际中断、关闭存储后恢复；确认三种终态、模型、父子身份、层级及近期时间，且只有根被加载、HTTP 请求数不增加。初次夹具使用不合法的 wiremock priority 0，改为 1；中断用例最初只等 Running，早于持久模型上下文，现等实际 HTTP 到达再中断并保留模型断言。

既有两项 Rust 断言曾把冷 completed 固定为 notLoaded，已更新状态预期，原关闭图、loaded:false、历史及隔离断言保留。最终 Rust workspace **190 项、0 失败/忽略**，严格 Clippy 与 fmt 通过，日志 `.cache/cold-overview-final2-rust-639.log`、`.cache/cold-overview-final-clippy-639.log`、`.cache/cold-overview-final-fmt-639.log`。Core 781 文件/六文件补丁、MCP 51 文件/四文件补丁来源审计通过，日志 cold-overview-core-audit-639.log / cold-overview-mcp-audit-639.log；没有 vendor/依赖变化。

初次 Swift 145 项通过，使用旧阶段 helper，仅证明该次 Swift 范围，日志 `.cache/cold-overview-associated-639.log`。最终 helper 首次关联 147 项有 1 项失败：旧关闭用例只伪造 UI shutdown，真实原生图仍 open；冷发现现正确替换其状态，原只读选择却可能受异步更新影响。生产端增加原选择关闭意图保护，测试改为核对原生 completed、loaded:false、无输入和请求不增加；真正 close_agent 仍由独立实际工具集成覆盖。该失败记录保留在 `.cache/cold-overview-final-associated-639.log`，不能记为全通过。

最终签名 helper 的关联复测 **147 项、0 失败/跳过、42.982 秒、exit 0**，日志 `.cache/cold-overview-final2-associated-639.log`；与初次集合重叠，不累加。冻结最终签名 helper `.cache/verified-agent-639-final/shipios-agent`，SHA-256 35bae070de0ac9c0e128ecc7d1c04a3bc646c3d1e2e004da234f299b594a6fc7。新增 Swift 用例还验证没有 UI 子记录的只读发现、错误根拒绝、无 HTTP 请求、独立草稿、同一子线程实际重试和父 runIDs 不变。

## 原生前台

使用 script/build_and_run.sh --app --data-root /private/tmp/shipios-ui-639/Data，初次正式 Swift 60.56 秒，最终冷启动 12.46 秒；日志 `.cache/cold-overview-formal-run-639.log` / `.cache/cold-overview-final-formal-run-639.log`。仅使用本机 127.0.0.1:64119 夹具，Key 留空。

新父任务 8EAC5A50-2FCE-4136-A816-35380DD9EC63，根 01a1152a-c978-75c4-93a5-d0ff3aae5467，子 Locke / 01a1152a-cb0d-74d4-af49-50bbfa9fceac。父完成、子完成；详情保留“state-child-retry 冷发现草稿🙂”。实际退出应用后，仅在自有隔离 workspace.json 清除该子名称/模型/摘要/时间等界面字段，将状态设为 notLoaded；原线程身份、持久历史、父任务、草稿及面板布局保留。

通过正式脚本重启，恢复的概览自动显示 Locke、活动 0 / 已完成 1。独立快照 after-cold-discovery.json 确认 loaded:false、completed、名称/模型恢复，HTTP **4→4**，父只有一个 runID。未点子详情即可完成此发现，证明不是通过加载子线程掩盖问题。

点击详情恢复完整草稿和 gpt-5.4 · 中，发送后实际出现 Child recovered on the same thread，草稿清空，返回仍活动 0 / 已完成 1。快照 after-cold-send.json 确认子 ID 保持、父一个 runID，HTTP 5；产品 recency 1791356488503→1791356625184，查询轮询未提前改变时间。多条列表的降序/同时间及等待分组有自动化证据，尚无本阶段多条列表和等待状态的完整前台配对证据。

最后通过正式脚本装入只读关闭选择保护并恢复默认数据根，Swift 2.72 秒、exit 0，日志 `.cache/cold-overview-final-default-run-639.log`。实际默认 other 工作区可点击输入，无持续恢复 loading；⌘, 在 ID main 打开设置，Esc 返回原输入焦点。严格签名、最终 helper IPC/Core RPC 冒烟均 exit 0，日志 `.cache/cold-overview-signature-639.log`、`.cache/cold-overview-ipc-639.log`、`.cache/cold-overview-core-rpc-639.log`；恢复后 helper 与上述冻结副本 SHA 一致。本机前台夹具正常 Ctrl-C 停止。

## 全量与剩余范围

第 635 篇固定提交 4bc7b5ee30ec5e283a16fbd41a29c331844503f2 的原 handle 30966 本轮取得 **exit 0**；Swift 2,746 项、2 跳过、0 失败（4,573.003 秒），Rust fmt/Clippy/tests、IPC 均通过。原 manifest 和终态状态文件保持，不覆盖第 636—639 篇，不能称最新源码全量通过。

V2/其他原生恢复和完整 runtime/discovery 投影、实时推理摘要/目标/差异/头像/时间呈现、全部权限/提问/输入边界、真实用户服务，以及 47 类全部页面和交互双端配对仍待继续。当前完成的是上述冷发现、分类及排序范围。提交后安排以本阶段提交、精确 helper、测试二进制及夹具摘要启动新的固定全量；其启动不作为通过证据，终态必须单独确认。
