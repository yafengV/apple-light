# 子任务概览运行耗时与完成时间

日期：2026-10-07。接续第 640 篇。范围仍为 21 类主窗口、26 类设置及 29 项核心要求；完整双端配对仍 **0/47**。本篇不代表整个子任务界面或全应用已经对齐。

## 参考与行为

只读当前 Codex 26.930.51102 / build 13100 的公开安装资源，没有读取个人配置、认证、历史或 Codex 自身前台。概览模块沿用第 639 篇副本，W 选择 lastAssistantMessageAtMs → recencyAtMs；完成项显示相对时间，等待项保留等待标签，非完成且有开始时间的条目显示耗时。活动项缺少时间时不显示通用状态替代时间。

新增核对 `task-elapsed-time-85deaaa13024.js`，副本 `.cache/subagent-elapsed-reference-641.js`，SHA-256 b9a4788816e896a013965af7034345d5c7fe68ba91ea4c8c4945e9adba063679；它每秒更新、将未来开始时间钳制为 0，并调用主模块 jR → 初始模块 dCc，使用窄英文单位、移除零单位。示例为 0s、59s、1m、1h 1s、1d。

主模块参考 `.cache/subagent-timing-primary-641.js`，SHA-256 234429db84d9319850ff0766a4a5052a9e898bfa0611883633f80018080dd6c0；初始模块 `.cache/search-reference-initial-633.js`，SHA-256 22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3。KQ/Noo/woo 以分钟、小时、本地日历天、周、月和年选择完成时间，最少一分钟；日历日差取整以处理夏令时。

额外核对中文资源 `zh-CN-3ed9eb1db28a.js`，副本 `.cache/subagent-time-locale-zh-CN-3ed9eb1db28a.js`，SHA-256 c6ac10a9fb407a393ea002d9aa818a4c7ed0e215e9c8bf0cfe2b798a98e3756f。中文完成时间单位为“分/小时/天/周/个月/年”，外层使用“{time} 前”，因此本机中文界面示例是“1 分 前”“2 小时 前”。运行耗时仍采用英文窄单位。公开资源研究不算双端操作验收。

## 实现

- Rust 向子任务快照增加可选 startedAtMs、lastAssistantMessageAtMs；已加载和冷线程均从原生历史读取，不以轮询时间补造时间、不加载冷子运行时、不提交父回合。
- 最新 TurnStarted 的原生秒时间转换为毫秒；没有可用回合时间时回退原生线程创建时间。助手消息优先使用所属线程、所属回合的 ItemStarted/ItemCompleted 开始时间；Legacy 公开 AgentMessage/ResponseItem 回退该消息回合的开始时间。新回合尚无助手消息时保持上次助手时间。消息 ID 按回合隔离，避免重试复用 ID 借用旧精确时间。
- 分页历史的继承前缀必须按真实 ordinal 排除。ThreadStore 的 replay vector 不带序号，故分页路径使用公开 RolloutLine reader/decoder 核对首条 canonical thread identity 和 subagent_history_start_ordinal；坏记录不改变后续记录的所有权。无法取得该契约时只保留创建时间回退，不伪造助手时间。该 reader 支持上游压缩格式，但本阶段没有压缩历史或完整 V2 会话的端到端验收。
- Swift 保留两个可选字段的 wire、持久化、加载和冷快照兼容。概览按状态显示等待标签/运行耗时/完成相对时间，使用等宽数字；运行每秒、完成每分钟刷新，行辅助功能值包括目标和时间。
- 没有修改上游 Core 源码、认证、模型配置、现有 16 个 HTTP/MCP 夹具或全量第 639 阶段的输入。

## 验证与失败记录

旧第 640 篇正式 helper 的实际 Core 集成测试出现 3 条时间缺失/重试未推进断言失败，`.cache/timing-before-641.log`，exit 1。时间修改后、中文格式修正前的关联组 251 项通过；不作为最终中文界面的验证结论。

最终正式 helper 冻结为 `.cache/verified-agent-641-final2/shipios-agent`，SHA-256 380bec2aac119df2c9755850f1aa6150dd14cb9403a2eb8d42eff39e7f54ae9b。

- Swift 最终关联组 **251 项、0 失败/跳过、57.912 秒、exit 0**：`.cache/timing-associated-final-641.log`。筛选 Subagent|TaskSummary|TaskWindow|CommandMenuSearchTests；集合有重叠，不与前次相加，也不算全应用测试。
- 其中实际 Core 集成核对原生历史 started_at 秒值、完成后的助手时间、清空界面缓存后冷恢复、请求数不增加、原子线程重试推进时间、委派目标及父 runIDs 保持。
- 4 项 Swift 格式/状态/持久化测试覆盖分钟至年边界、零单位、未来时间、夏令时跨周、助手/近期/观察时间优先级及旧数据；已包含在 251 项内。
- Rust 新增 3 项测试覆盖 Legacy、精确消息开始时间/线程及回合所有权、分页原始序号和坏记录排除。最终正式 helper 的 Rust 工作区 **195 项、0 失败/忽略、exit 0**（`.cache/timing-rust-formal-final-641.log`）；最终 fmt 和 Clippy -D warnings 亦通过（`.cache/timing-fmt-final-641.log`、`.cache/timing-clippy-final2-641.log`）。
- 正式脚本构建运行、严格深度签名、最终 IPC 和 Core RPC 冒烟通过，日志分别为 `.cache/timing-formal-final2-run-641.log`、`.cache/timing-signature-final-641.log`、`.cache/timing-ipc-final-641.log`、`.cache/timing-core-rpc-final-641.log`。

一轮 Rust 全量与随后默认 Cargo helper 单项复测均出现既有原生补丁审批完成状态等待超时，保留 `.cache/timing-rust-final3-641.log`、`.cache/timing-patch-approval-repeat-641.log`，均失败。没有放宽原断言/期限；只为该测试补充超时时的原生状态与最后公开历史。随后单项诊断通过，正式 helper 和默认 Cargo helper 各连续三次通过（`.cache/timing-patch-formal-repeat-641.log`、`.cache/timing-patch-debug-diagnostic-641.log`）。根因尚未确认，不能将复测通过写成超时已修复。先前 `.cache/timing-rust-final4-641.log` 的 195 项工作区通过亦保留为当时结果。

## 前台与剩余范围

Mac 锁屏且自动解锁失败，已存在手动解锁请求。本轮正式包的实际时间绘制、连续跳秒、辅助功能读值、点击详情/返回与默认工作区可交互仍待验收；构建、启动和自动化通过不能替代这些证据。

仍需完成子任务精确头像/差异统计、全部摘要和委派包装、其余权限与提问/输入、完整 V2 与其他恢复路径，以及全部页面双端配对。新增热线程历史读取的长历史性能也需继续验证。

第 639 篇固定提交 a2216db 的原全量 session 73780 已确认仍运行；其默认缓存、16 个夹具、测试二进制及冻结 helper 校验未变。本轮仅使用 `.cache/native-ui-632` 作为 Swift 构建/测试缓存。该旧全量即使通过也不覆盖第 640/641 篇。
