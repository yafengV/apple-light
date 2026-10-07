# 子任务概览的委派目标与公开摘要

日期：2026-10-07。接续第 639 篇。范围仍为 47 类页面/控件和 29 项核心要求；完整双端配对仍 **0/47**。

## 参考与差异

参考当前安装包公开资源 Codex 26.930.51102 / build 13100：第 639 篇的概览模块 `local-conversation-subagents-panel-tab-797735e5898b.js`（SHA-256 d87313d9ce52d9e65f0d5886c84648b6f59ea8af806a176214d5b8d16a2b4c19）中 V 优先使用 objective，经纯文本化和 60 UTF-16 单位限长；否则使用 statusSummary；完成且均无内容时不显示摘要，其他状态回退 Working。主模块的 Tet 从父线程协作工具调用保留最新非空 prompt，Ret/Bet 从当前进行中的回合取最新公开思考摘要，移除列表/标题/强调、第一人称前缀和尾标点。

本阶段另读取 `app-shared-9d148924be0b.js` 的 WV/VV：副本 `.cache/subagent-shared-reference-640.js`，SHA-256 eb2500c5398279d4fbf5c71d7ce982d54631660907761740199f6c22591d71ab。WV 先压缩空白，超长为前 59 单位与省略号。只读公开静态资源，不访问 Codex 自身前台、配置或个人历史；静态研究不算完整双端验收。

旧 ShipiOS 概览使用最后回复 preview；即使完成，也会用回复替代原委派目标。本阶段将这两种数据分离，preview 仍保留在原生元数据，概览采用新的 objective 与当前公开摘要。

## 原生与界面实现

- Rust 从每个直接父线程的持久历史恢复目标，一次快照每个父线程只读一次。不从子线程第一条用户消息推断，避免误用 fork 继承的父任务内容；最终行必须仍属于该父线程。
- Legacy：只匹配内置命名空间或旧无命名空间的 spawn_agent/send_input；按 call_id 配对实际成功返回，spawn 要有合法 agent_id，send_input 要有 submission_id 和 UUID target。失败、未配对、其他工具命名空间和复用的旧 call_id 不改写目标。支持 message 和 items 中的公开文本。
- Paginated：支持所属线程与 sender 都匹配的 ItemCompleted / CollabAgentToolCall；公开协作通知也能提供目标，但不将它当作唯一持久来源。新非空委派覆盖旧目标，空白不覆盖。
- objective 是最多 1,024 Unicode 字符的概览元数据，不加载冷子线程，不提交模型回合。Swift wire/持久模型字段可缺省，旧数据继续解码；详情加载与冷快照合并保留它。
- 概览把目标转为纯文本、压缩空白并限长；省略号边界遇到 UTF-16 高代理时退一个单位，避免无效字符。没有目标时，仅当前 active 回合的公开思考摘要可回退；完成、等待及旧回合不会借用旧摘要，原始推理从不用于概览。目标也作为行的辅助功能值。

## 失败证据与修正

旧签名 helper 的新真实 Core 集成用例，在完成、清空界面缓存后的冷发现及同一子线程续聊后三处 objective 断言均失败：`.cache/objective-before2-640.log`，1 用例/3 失败，exit 1。首次基线构建因源文件在编译期间变化中止，`.cache/objective-before-640.log`，不能算功能验证。

第一版仅解析协作通知，纯提取测试通过但正式 helper 的关联组仍 247 项/3 失败；日志 `.cache/objective-associated-640.log`。正式应用截图也显示 Locke 行无目标。查阅锁定上游 rollout policy 确认 Legacy 将协作通知作为暂态，并依靠原始 FunctionCall/FunctionCallOutput 持久化；随后增加上述持久格式解析，没有修改上游持久化策略。首次协议测试夹具还把 reasoning_effort 写为 null，改为协议要求的字符串；首次 Swift 测试 JSON 原始字符串与内容定界符冲突，修正后再验证。保留失败日志，不算通过。

## 验证记录

- Rust 最终 workspace **192 项、0 失败/跳过、exit 0**：`.cache/objective-rust-final2-640.log`；包括 106 项 sandboxing 测试，不是上游 Codex 全套测试。最终 fmt / Clippy -D warnings 通过：`.cache/objective-fmt-final-640.log` / `.cache/objective-clippy-final2-640.log`。
- Swift 最终精确签名 helper 关联组 **247 项、0 失败/跳过、55.646 秒、exit 0**：`.cache/objective-associated-final-640.log`。命令筛选 Subagent|TaskSummary|TaskWindow|CommandMenuSearchTests，范围包含相关名字的其他测试，不能视为全应用测试；与前次集合重叠，不累加。
- 新集成用例实际通过 Core spawn：完成时目标来自委派而非父提示/子回复；移除 UI 子记录并重连后冷发现目标、loaded:false、HTTP 数不增加；同一子线程实际重试改变最终回复，但不改变父委派目标或父 runIDs。
- 4 项纯呈现测试覆盖 Markdown/空白/UTF-16 边界、目标优先、当前公开摘要、旧/终止回合和原始推理排除、wire 及旧持久兼容；`.cache/objective-preview-ax-640.log` exit 0。它们已包含在最终 247 项中。
- 最终正式构建通过：`.cache/objective-formal-final-run-640.log`，Swift 3.25 秒。精确 helper `.cache/verified-agent-640-final2/shipios-agent`，SHA-256 **6d6ef1b5eec5aa00937240f5f44430ae7d654123a09130336c137e0cdae4cf02**。最终严格签名/IPC/Core RPC 均 exit 0：`.cache/objective-signature-640.log`、`.cache/objective-ipc-640.log`、`.cache/objective-core-rpc-640.log`。

使用前阶段自有数据 `/private/tmp/shipios-ui-639/Data` 冷启动最终正式包。程序恢复快照 `.cache/objective-native-restore-640.json` 记录原 task 8EAC5A50-2FCE-4136-A816-35380DD9EC63、子 01a1152a-cb0d-74d4-af49-50bbfa9fceac：objective 为 state-child-hold，completed/loaded:false，原最终回复保持 Child recovered on the same thread，父只有原一个 runID。该阶段本机 API 夹具未启动；恢复读持久历史，没有提交模型回合。

**前台边界**：第一版正式包确实在可交互窗口看到无目标，促成持久格式修正；最终包 UI 验收时 CUA 明确报告 Mac 锁定且自动解锁失败。已请求手动解锁，最终目标实际绘制、行辅助功能值及点击详情/返回尚待前台验证。恢复快照、构建与进程均不能替代这项证据。默认工作区已通过同一正式脚本恢复启动（`.cache/objective-default-run-640.log`，exit 0、Swift 0.85 秒），helper 摘要与最终冻结版本一致；再次检查仍锁屏，不宣称当前工作区可交互。

## 剩余边界

本阶段不宣称全部子任务页面已对齐。仍包括完整 V2/其余恢复路径、Legacy 非 UUID target 别名、全部委派包装/HTML 与特殊 Markdown 的精确呈现、实时差异统计、精确头像、运行/完成时间、其他权限与提问、全部输入操作及前台双端配对。概览截断处的有效 Unicode 处理与上游 UTF-16 slice 存在明确边界差别。

第 639 篇固定提交 a2216db 的全量继续使用冻结 helper/测试二进制、默认 `.cache/macos-build` 与原 16 个夹具；本阶段所有 Swift 构建/关联测试使用 `.cache/native-ui-632`，没有覆盖其冻结输入。该全量即使通过也不覆盖本阶段。完整对齐目标保持未完成。
