# 中断回合与后台终端清理

接续[SessionEnd 收尾](609-session-end-event-drain-and-history.md)。本阶段补上真实 Core 后台终端的独立清理通道，并验证 Interrupt 生命周期和审批取消边界。后台任务摘要列表、清理按钮和输出内容标签尚未实现，不能把这一后端阶段描述为 UI 已对齐。

## 参考依据与行为

本机公开参考版本 26.930.21537 的 `app-shared-59042e7300f7.js` 中，活动回合通过 `turn/interrupt` 中断；后台终端通过独立 `thread/backgroundTerminals/clean` 清理。停止回合还涉及独立的 node_repl 收尾，不能把它误当作统一执行终端的清理。没有活动回合时，中断入口可转到后台终端清理。

锁定 Core `unified_exec/process_manager.rs` 明确保留执行会话，使回合中断不会丢掉最后一个 Arc 而终止进程。`session/handlers.rs` 的 `clean_background_terminals` 调用 `close_unified_exec_processes`。App Server 的清理响应确认提交操作，不等同于操作系统进程已经退出。

公开客户端 `local-conversation-thread-3f5a28c45846.js` 的摘要 `nx`/`Tx` 分支从已结束回合中找仍运行的命令，显示终端图标和命令文本，点击打开后台终端输出内容标签。每行的“Stop all background terminals”清理整个会话；一次操作期间全部行按钮禁用，所选行显示等待，失败显示通知。这里仅作为后续前台实现要求，没有宣称已取得双端操作证据。

Interrupt Hook 的原生输入含 session/turn/cwd/model/permission 等字段，不含 reason。回合中断后执行 Hook，真实 runtime turn ID 应继续对应原回合；不能把测试假设的 reason 注入产品。

## 已实现

- Core 通过 `Op::CleanBackgroundTerminals` 清理当前线程的统一执行进程，不关闭线程或删除历史。
- Agent 命令按已绑定 task ID 定位 Core 线程，等待提交结果；`codex.thread.backgroundTerminals.clean` 只接受精确 taskId 参数。
- macOS 独立会话传输提供清理方法，拒绝未连接会话；RPC 返回 submitted，保留原生“提交”语义，不伪造已退出结果。
- 真实命令测试写出 shell PID 和开始标记，确认部分输出、原生中断 Hook、后台进程存活、显式清理后 PID 消失、同项目另一任务进程仍存活、没有执行后续完成标记；原会话可续聊，Hook 历史可恢复。
- 审批等待期间停止的用例验证审批卡片清理、过期批准不能执行命令、Interrupt 非零退出错误保留、停止不受失败 Hook 阻塞，原任务可以继续。

## 测试失败的定位

第一次用例假定回合停止会杀掉统一执行进程，且 Hook 输入含 reason；两个断言与原生 Core 不符，按公开代码和实际 PID 结果纠正。第二次用例在启动另一任务时耗尽第一回合的夹具回复等待，导致第一回合已经 succeeded，未真正覆盖运行中停止。现先启动同项目另一任务，再启动并停止目标回合，同时明确断言其仍 running；没有放宽取消、进程、输出或 Hook 断言。调整后的真实进程用例通过，17.425 秒，见 `.cache/interrupt-clean-core-tests.log`。

## 验证记录

- 最终 Rust 工作区 **168 项通过，0 失败/跳过**，包括合法但未绑定 UUID、错误参数类型和额外线程范围拒绝；`.cache/interrupt-clean-rust-final-tests.log`。`cargo fmt --all -- --check` 与 Clippy `-D warnings` 通过；`.cache/interrupt-clean-clippy.log`。Cargo 保留既有 patch/依赖未来兼容性提示。
- 最终关联 Swift **105 项通过，0 失败/跳过**，216.783 秒：15 项 Hook 统计/生命周期、4 项启动取消和 86 项模型传输；`.cache/interrupt-clean-related-tests.log`。
- 最终签名应用包内 Agent **19 项通过，0 失败/跳过**，53.612 秒：15 项统计/生命周期及 4 项启动取消；`.cache/interrupt-clean-bundled-tests.log`。这批与 105 项重叠，不相加冒充不同用例。
- `script/build_and_run.sh` 构建、签名和 LaunchServices 启动 exit 0；`.cache/interrupt-clean-app-run.log`。严格深度签名 exit 0；`.cache/interrupt-clean-signature.log`。
- 最终包内 Agent IPC 冒烟 exit 0：真实 doctor、流式事件、重放、报告/日志、立即重跑、构建取消、重启持久化和帧限制；`.cache/interrupt-clean-ipc-smoke.log`。
- 新包前台读取返回 Mac 锁定且自动解锁失败；没有确认工作区可交互，未将进程或启动命令成功替代页面验收。

前一全量回归 session 21812 已确认终态 exit 0：覆盖提交 `f274f79`，2,586 项 Swift、0 失败、2 项语音夹具跳过，IPC 冒烟通过，见 `.cache/full-alignment-regression-607.log`。它不覆盖第 608—610 篇，原文“仍在运行”仅是当时状态。

## 剩余范围

- 在主窗口、任务窗口接入后台任务摘要行、忙碌/错误反馈和原生输出内容标签，保持窗口与任务归属；回合结束后的输出/完成事件当前仍需独立路由。
- 没有活动回合时的 Stop 清理回退、node_repl 与所有执行类型的停止行为。
- 提问、MCP/其他 Hook 事件、异步与超时、即时停用的完整生命周期矩阵。
- 真实前台及 Codex 同版本双端逐页配对；完整验收仍为 0/47。
