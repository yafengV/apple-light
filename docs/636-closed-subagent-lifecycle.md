# 原生关闭子会话的状态、列表和冷历史

日期：2026-10-07。接续[第 631 篇](631-cold-subagent-reload.md)的真实关闭生命周期缺口。原有测试预设 UI shutdown，不足以证明实际 close_agent；本阶段以实际 Core 工具验证关闭，再补齐持久状态与列表呈现。全产品 47 类页面、29 项核心要求保持，完整双端配对 **0/47**。

## 参考和失败复现

从本机 Codex 26.930.51102 / build 13100 的公开 app.asar 重新提取 app-primary-c0280d43ce72.js：2,328,172 字节，SHA-256 234429db84d9319850ff0766a4a5052a9e898bfa0611883633f80018080dd6c0，与先前缓存一致。子任务投影函数在 latestReference.tool 为 closeAgent 时返回 null；shutdown/notFound 等状态也有隐藏规则。本阶段补齐明确的关闭过滤，其他失败/中断/运行状态投影仍须接续；不能据此宣称整套列表完全对齐。没有操作 Codex 自身前台，也未读取个人配置或认证。

新增本机 Responses 夹具，让固定 Core 实际执行 spawn_agent 和 close_agent。前两次夹具超时：首版 tool_search 缺少 execution:client，父用户消息又带宿主上下文前缀；第二次诊断确认只发送了一条无效发现请求。修正夹具协议和文本识别后，旧生产代码稳定产生 **1 项、5 条断言失败、0 unexpected、exit 1**，日志 `.cache/closed-child-ready-before-636.log`：关闭后仍显示 completed、冷详情变为 loaded/可输入、直接加载 RPC 接受已关闭线程。初始夹具错误不计生产缺陷。

## 修改

- CodexSession 与 DescendantSource 共享 Core 使用的原生 AgentGraphStore。以全部边和仅开放边的可达集合之差识别关闭线程，包括开放边位于关闭祖先之下的情形；普通 cold/open 线程继续可恢复。
- 每次自动恢复祖先前重新核验图状态，关闭线程返回 closed 错误；只读持久历史不受此限制。不写入图状态，不修改原生 close_agent/resume_agent 实现。
- 原生 snapshot 将已关闭条目投射为 shutdown；Swift 只对普通 notLoaded 回退旧终态，不再用旧 completed 覆盖明确 shutdown。详情准备重新读取当前子状态，避免旧选中对象重开刚关闭的会话。
- 列表和摘要移除 shutdown，不计为已完成；已打开详情保留历史并移除输入器，原草稿继续独立持久化。保留原记录供历史读取，不删除会话数据。

新增直接依赖 codex-agent-graph-store，仍固定同一上游版本；该包此前已是传递依赖，Cargo.lock 只增加宿主依赖列表中的一行。本阶段没有 vendored Core/MCP 修改。Core 781 文件/六文件补丁、MCP 51 文件/四文件补丁来源审计通过，日志 `.cache/closed-child-core-source-audit-636.log`、`.cache/closed-child-mcp-source-audit-636.log`。

## 自动验证

第一项真实关闭/冷恢复修复后通过。尝试由模型生成孙线程的第二项遇到固定 Core 默认深度限制，未发现 spawn 工具，不能算通过，也未为测试改变生产深度；该尝试日志 `.cache/closed-child-focused-636.log`。随后改为实际两任务隔离集成，并另加原生持久图祖先边界测试。

最终两项实际 Core 集成 **0 失败/跳过、4.706 秒、exit 0**，日志 `.cache/closed-child-final-focused-636.log`：实际关闭、旧详情对象、重启后只读历史、直接 RPC 拒绝自动恢复；关闭一个任务的子线程不影响另一任务的已完成且可交互子线程。

原生 Rust 专项 1 项通过，日志 `.cache/closed-child-graph-636.log`，覆盖关闭孙线程、关闭祖先、开放同级、只读历史与不发送模型请求。该专项使用真实原生线程和存储 API，但直接设置关闭边；真正 close_agent 执行由 Swift 集成和前台分别证明。

最终 Rust fmt、Clippy -D warnings、workspace **188 项、0 失败/忽略、exit 0**，日志 `.cache/closed-child-final2-fmt-636.log`、`.cache/closed-child-final2-clippy-636.log`、`.cache/closed-child-final2-rust-636.log`。Swift 子会话/审批/表单/输入/草稿/附件/冷恢复扩大回归 **99 项、0 失败/跳过、46.006 秒、exit 0**，日志 `.cache/closed-child-associated-636.log`。

一次并行准备 Swift 构建时修改了同一输入文件的缩进，编译器拒绝该次构建，日志 `.cache/closed-child-swift-build-636.log`；后续重新构建并完成上述测试，未沿用失败构建结果。

## 正式包和前台

使用 script/build_and_run.sh --app --data-root /private/tmp/shipios-ui-636/Data，Swift 5.17 秒、exit 0，日志 `.cache/closed-child-formal-run-636.log`。严格签名、包内 IPC、Core RPC 本机冒烟通过，日志 `.cache/closed-child-signature-636.log`、`.cache/closed-child-ipc-636.log`、`.cache/closed-child-core-rpc-636.log`。服务只绑定 127.0.0.1，API Key 留空，仅在隔离设置填写本机地址和 Responses 协议，没有外部 API 请求或真实用户服务验证。

实际 CUA 验证：创建 parent-spawn，实际 Hubble 子线程完成；从摘要进入列表，再进入详情，看到 Native child history remains readable 和可用输入器。填写“保留关闭前草稿🙂”，在父输入发送指定线程的 parent-close。父显示 Parent closed child，已打开的子历史保持，子输入器消失。返回列表后仅显示活动 0，无已完成条目；摘要不再显示子任务入口或计数。

通过正式脚本重启同一隔离根，日志 `.cache/closed-child-restart-run-636.log`，列表/摘要仍隐藏已关闭线程，父两次运行和回复保持。夹具请求 **7→7**、父 runIDs 相同，记录在 `/private/tmp/shipios-ui-636/before-restart.json` 和 after-restart.json；独立 workspace.json 仍保存 shutdown/loaded:false 和原关闭前草稿。没有自动续轮。

最后通过正式脚本恢复默认根，Swift 0.19 秒、exit 0，日志 `.cache/closed-child-default-run-636.log`。CUA 确认 other 无持续 loading、任务输入可点击；⌘, 在 ID main 打开设置，Esc 返回并恢复原输入焦点。自有回环服务器随后正常以 Ctrl-C 关闭。

## 验证边界与后续

签名前 debug helper 与正式包 helper 的原始 SHA 不同，因此不把第一次 99 项记作包内精确来源复测。正式包 helper 的精确副本已另行冻结，SHA-256 6c579cb2df5bc8b6801311c1c4f94d8b64323352be41ac7acd92541b662fd739，记录 `.cache/closed-child-final-agent-shas-636.log`；包内精确来源的同组复测 **99 项、0 失败/跳过、44.083 秒、exit 0**，日志 `.cache/closed-child-final-bundle-associated-636.log`，与先前集合重叠，不累加。

第 635 篇固定 4bc7b5e、测试二进制和 helper 的全量仍须等待原 handle 30966 终态，不覆盖本阶段；其缓存 `.cache/native-ui-632` 和既有夹具未改动。首次外层沙箱运行已终态因 Seatbelt/测试偏好域权限失败，日志 `.cache/full-alignment-regression-635.log`；同一固定输入经原生测试权限重新运行于 `.cache/full-alignment-regression-635-final.log`，Rust 已通过、Swift 仍运行，不能计全量通过。

V2 全路径、明确 resume_agent 重新开放后的完整输入/空闲呈现、其余状态投影、所有窗口/权限/工具、真实模型和完整 Codex 双端配对继续未完成；本阶段不将这些边界收缩为关闭链路已经全覆盖。
