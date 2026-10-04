# 原生子任务中断与会话关闭

接续[空闲停止和操作身份](612-idle-stop-background-cleanup.md)。本阶段将已存在的原生 Core 子任务树接入根会话中断与关闭，不将后台终端清理当作所有执行类型的取消。完整 UI、独立 Node 运行时和其余核心功能仍须继续对齐。

## 参考与能力边界

参考版本 26.930.21537 的公开 `app-shared-59042e7300f7.js`，`I8t`/`L8t` 根据缓存与重新发现的任务树停止活动后代，排除已完成会话；用户停止的后代发现可在后台执行。失败记录 warning。`N8t` 的 Node REPL 取消是另一个路径，不能由统一命令清理代替。

固定上游 `50d77959bf927293c4b5ddcca81d05331ae582ea` 的 `Feature::JsRepl` 已标记 Removed、默认关闭；项目当前没有独立 Node executor。它不能靠打开旧 feature 配置补齐。Core 的 `ThreadManager::list_agent_subtree_thread_ids` 会合并持久 spawn 图与活动注册表，`CodexThread::agent_status`/`submit` 和受限关闭 API 可用于本阶段的原生收尾。

以上读取均为公开应用资源和固定依赖源码；没有读取个人认证、配置或会话，也没有进行 Codex 前台操作。

## 已实现

| 情形 | 当前行为 | 验证边界 |
| --- | --- | --- |
| 根回合中断 | 先提交根 `Op::Interrupt`，再在会话拥有的后台任务中发现后代 | 父停止不等待子树完成；原统一命令后台进程语义保留 |
| 活动子任务与孙任务 | 只向实际 spawn 子树中 Running/PendingInit 的已加载线程提交中断，并发收尾 | 不向无关根线程广播；不重载冷历史 |
| 已完成、错误或已关闭后代 | 保持其状态和历史 | 不将这些线程重新启动来执行停止 |
| 子任务中断失败/发现超时 | 10 秒界限，终止尚未完成的宿主收尾工作，记录不含内容/凭据的计数日志 | 提交确认不等于所有实际回合已终止；实际状态另由测试等待 |
| 会话关闭 | 根 SessionEnd/ShutdownComplete 继续按原路径读取，然后取消并等待宿主收尾工作，并受限关闭该私有 manager 的剩余线程 | 在释放独立认证/目录锁前收尾；失败返回错误，不能当作成功关闭 |
| 同项目另一任务 | 保留其独立 manager、原生线程及进行中的请求 | 没有按项目或进程名批量停止 |

线程树查询和关闭使用任务私有的原生 manager，不改变模型/API 配置来源。关闭受管线程也包含同 manager 中的辅助线程，不能遗留正在运行的线程后立即释放任务认证环境。根事件读取保持单一消费者。

## 验证

新增两项真实 Core 测试，用本机 HTTP Responses 夹具建立原生线程与持久 spawn 关系：

- 父/子/孙均进入实际请求后停止父任务；子/孙达到 Interrupted，无关根线程仍 Running，已完成且移出注册表的历史保持完成且不重载。被中断子任务随后完成新回合。父停止入口不等待后台树发现。
- 根关闭与正在进行的后代清理竞争；子线程达到 Shutdown、私有 manager 为空，同项目另一独立会话继续 Running。原独立目录可以重新打开，验证目录锁已释放。

初次测试编译因辅助函数与变量同名失败，已改名并重新执行。专项两项通过；之后补充冷历史测试资源显式关闭和后台工作失败日志，完整 Rust 工作区 **170 项通过，0 失败/忽略**，含两项原生用例；`.cache/descendant-rust-workspace.log`。严格 Clippy（全部 target，`-D warnings`）与 fmt 检查通过；`.cache/descendant-clippy.log`。

组合验证请求曾因自动审批审查超时而未执行，改为逐项离线缓存检查后通过；该超时没有作为代码失败或测试通过计数。

- 新 Agent 的 Swift 关联 **125 项通过，0 失败/跳过**，217.842 秒；`.cache/descendant-swift-regression.log`。包括全部 86 项模型传输、15 项 Hook/中断/SessionEnd、20 项后台终端和 4 项启动取消。
- 正式 `script/build_and_run.sh` 构建、签名及 LaunchServices 启动 exit 0，Swift 构建 5.17 秒；`.cache/descendant-app-run.log`。严格深度签名 exit 0；`.cache/descendant-signature.log`。
- 最终签名包内 Agent **39 项复测通过，0 失败/跳过**，60.067 秒；`.cache/descendant-bundled-regression.log`。涵盖后台终端、Hooks/中断/SessionEnd 和启动取消，与前述 125 项重叠，不累计冒充不同用例。
- 最终包内 Agent IPC 冒烟 exit 0：doctor、流式事件、重放、报告/日志、立即重跑、构建取消、重启持久化及帧限制；`.cache/descendant-ipc-smoke.log`。
- 新签名包前台读取再次返回 Mac 锁定且自动解锁失败，没有确认可交互工作区；启动成功、进程存在和隐藏窗口测试不代替实际前台验收。

本阶段没有改动 Swift 源码；关联测试使用第 612 篇已编译的最终 Swift 测试程序、明确指定新构建 Agent，而不是复用旧 Agent 结果。原生子/孙任务的直接验收属于上述 Rust 两项，不将没有子树的普通会话回归冒充子任务页面验证。

## 仍须完成

- 独立 Node REPL executor、按回合取消及持久上下文；不能声称本阶段实现了 Node 工具。
- 完整子任务时间线/统计/状态呈现、父回合已经结束但子任务仍活动时的前台停止入口、缓存优先与重新发现竞争、所有 descendant goal/授权及回合身份边界。
- 真实模型自主委派、全部协作工具与前台操作配对。这里的原生测试直接通过 Core API 建立受控线程，不能代替模型自主调用或实际页面验收。
- 全部 47 类页面/控件与 29 项核心要求保持[完整矩阵](599-core-function-parity-matrix.md)的范围；完整双端配对仍为 0/47。
- 保留的全量 handle 16667 编译于 `acd3b67`（第 612 篇），不覆盖本阶段新 Rust 源码。没有因日志缓冲或等待超时重新启动它。
