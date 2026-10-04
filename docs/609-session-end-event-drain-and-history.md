# SessionEnd 事件完整收尾与历史归属

接续[Hook 统计与历史](608-hook-run-statistics-and-history.md)。本阶段修复停止线程、变更 API 服务和应用关闭期间丢失的原生 SessionEnd 通知，覆盖 Core、Agent stdio、主应用读取和历史持久化。它是核心完整性修复，不代表整个 Hooks 页面或全部 UI 已完成配对。

## 问题与参考依据

真实应用状态 → Agent → Core → shell 用例首先证明：SessionEnd 命令写出了完成文件，但其运行记录没有进入历史。此前 `CodexSession.shutdown` 等待运行时退出却不读取事件；Agent 随即中止广播转发；主应用可能先处理进程终止，再丢弃尚未消费的 stdout。即使通知到达，SessionEnd 新建的内部 turn ID 也会被原有严格用户回合匹配拒绝。

锁定的公开 Core `hook_runtime.rs::run_session_end_hooks` 使用 `new_default_turn`，SessionEnd 是 thread scope，并保留独立内部 turn ID。`hooks/src/events/session_end.rs` 规定默认一秒、最多三秒，async SessionEnd 强制同步，非零退出采用 stderr 或缺省退出码错误；成功不把 stdout 当成统计消息。正常关闭顺序是 SessionEnd 后发送 ShutdownComplete。

公开参考客户端 26.930.21537 的 `app-shared-59042e7300f7.js` 保留通知的 turnId，由 `updateTurnState` 查找回合：started 允许绑定正在运行的占位；未匹配内部回合的实际前台呈现尚未取得双端证据。这里不把 ShipiOS 的 thread 生命周期历史归属策略宣称为 Codex 前台已完全一致；精确统计呈现仍在配对缺口中。没有读取个人 Codex 配置、认证或历史。

## 已实现与验证范围

| 内容 | 当前行为 | 验证方式 |
| --- | --- | --- |
| Core 事件读取 | 关闭同时读取事件，直到 ShutdownComplete；运行时结束后仍读取已排队通知，有界等待且缺少终态报告错误 | 真实 Core SessionEnd、原有 Rust 回归 |
| 终态持久边界 | TurnComplete/TurnAborted 必须先 flush rollout；失败不发布该终态 | 保留原有约束，原生分叉/恢复关联回归 |
| Agent Stop | 显式停止及收尾兜底转发全部原生事件，保留 task/thread | 显式 stop 后实际完成记录 |
| Agent EOF | 关闭广播生产者，先让转发器读完，再关闭输出；停止读取的客户端仍受有界等待保护 | 真正 EOF 后命令、错误、历史保存与恢复 |
| 多个 Core | 同 Agent 内的独立线程同时开始关闭 | 两个实际 Hook 必须都创建就绪文件后才结束 |
| 多个 Agent | 应用同时向独立项目 Agent 发出 EOF，避免逐个累计等待 | 两个项目外任务的同一真实门槛；同项目另验证单 Agent 路径 |
| 最后 stdout | Process 终止不提前失效原 generation，等待有序 stdout 消费者完成；保留强制退出上限 | 真实 EOF 集成及启动取消/模型通道回归 |
| 历史归属 | 仅原生 thread scope SessionEnd 可使用独立内部 turn ID；绑定该 thread 的最后一个已有回合，排除新服务未绑定回合；其他事件仍按真实 turn 匹配 | 未知 task/thread/turn、重复通知、待启动回合、旧线程及真实服务变更 |
| 原始边界 | 保存 scope 与 runtime_turn_id，不改写用户回合的 codex_turn_id；旧历史可继续解码 | 原生内部 ID 不等于用户回合 ID、恢复及旧记录测试 |
| 保存 | Agent 完整关闭后再次保存会话库 | 重启恢复失败条目和原回复 |
| 超时/失败 | 保留 Core 原始失败和错误；超时命令不能执行其后续完成写入 | 真正 shell 默认超时、stderr 失败、async 强制同步 |

## 验证记录

初始真实 EOF 用例失败，命令执行文件存在而统计缺失；日志 `.cache/session-end-before.log`。第一轮修复后 10 项统计用例通过。扩展夹具最初错误地只改全局默认模型（旧任务保留自己的模型选择），并将第二轮提交到同一任务，已分别改为实际 API 地址变化和显式新建任务，保留失败记录。

修正后的服务变更通过，多会话用例复现第一条 Hook 因逐个关闭而超时，见 `.cache/session-end-boundaries-repro.log`。Agent 内改成并发后，项目外用例继续失败，进一步证明主应用也在逐 Agent 关闭。现两层均并发，分别覆盖共享项目和独立项目外目录。测试不以进程退出或一个虚构计时结果代替真实同步命令完成。

测试夹具曾将新增的三秒参数错误默认成所有 Hook 一秒，导致原有两秒 async 用例超时，见 `.cache/session-end-complete-stats-tests.log`。现只在多会话用例显式设置三秒，其余保留 Core 默认值，不削弱 async 执行断言。

- 最终 Rust 工作区 **167 项通过，0 失败/跳过**；`.cache/session-end-final-rust-tests.log`。`cargo fmt --all -- --check` 和 `cargo clippy --workspace --all-targets --locked --offline -- -D warnings` 通过，Clippy 日志 `.cache/session-end-clippy.log`；Cargo 保留既有未使用 patch/依赖未来兼容性提示。
- 关联 Swift **122 项通过，0 失败/跳过**，270.292 秒：13 项 Hook 统计、7 项原生分叉、4 项启动取消、12 项 Hook 设置和 86 项模型传输；`.cache/session-end-related-final-tests.log`。最终只将输出等待标记移到成功启动之后，避免不存在的进程额外等待；这条收尾修正由下一批捆绑测试覆盖。
- 最终正式包 Agent 的 **17 项通过，0 失败/跳过**：13 项统计及 4 项启动取消；`.cache/session-end-complete-bundled-tests.log`。它与 122 项重叠，不相加计数，覆盖最终源文件及两层并发真实门槛。
- 最终 `script/build_and_run.sh` 构建、签名、LaunchServices 启动 exit 0；`.cache/session-end-release-app-final-run.log`。严格深度签名 exit 0；`.cache/session-end-final-signature.log`。
- 最终应用包内 Agent 的实际 IPC 冒烟 exit 0：doctor、流式事件、重放、报告/日志、立即重跑、构建取消、重启持久化、帧限制；`.cache/session-end-final-ipc-smoke.log`。
- 原生前台工具读取正式 ShipiOS 返回 Mac 锁屏且自动解锁失败。本阶段不能确认可交互工作区、统计弹层的前台操作或任何 Codex 双端完整配对，不能把构建运行命令成功作为替代证据。
- 保留的全量 session **21812** 已再次确认仍运行，覆盖 `f274f79`，`.cache/full-alignment-regression-607.log`。未重启或占用其默认构建缓存；它不覆盖第 608/609 篇，本阶段没有宣布最新全量通过。

## 剩余范围

- 真实前台打开/选择复制/滚动/关闭焦点，以及同版本 Codex 的 thread 生命周期统计呈现配对。
- 活动工具、审批/提问、PermissionRequest、Compact、Interrupt、Subagent 等全部生命周期；运行中即时停用、异常磁盘及其他来源完整矩阵。
- 被强制 SIGKILL、客户端不读 stdout 等情况下不能保证已丢失的通知恢复；仍需完整故障审计，不伪造成功。
- 用户真实 API、GitHub、完整插件包、其余核心与页面要求。

完整页面配对仍为 **0/47**，范围及未完成项继续以[核心与全部页面矩阵](599-core-function-parity-matrix.md)为准。
