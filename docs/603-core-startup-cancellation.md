# Core 启动期间停止、共享等待与关闭清理

接续[第 602 篇](602-archive-stream-startup-regression.md)及[核心矩阵](599-core-function-parity-matrix.md) C04/C06/C12。启动中的 Core 会话原先等待共享 `Task.value`，取消调用者不能结束等待；关闭也没有收集尚未初始化的进程。停止后任务继续显示 running，等初始化完成才收尾。

## 修复前的实际证据

私有包装脚本记录真实 PID，延迟 6 秒后 exec 实际 Agent，模型端是独立本机 HTTP 夹具。第一次直接传输测试用了无效任务 ID，纠正为 UUID 后重新建立基线；旧运行不算有效的共享启动证明。

正确基线（`.cache/core-startup-cancel-baseline.log`）3 项、4 个断言失败、没有未预期错误：共享等待取消耗时 6.170 秒，关闭及等待收尾 6.066 秒，Store 停止及收尾 6.105 秒；Store 停止后原 Agent PID 仍存活。这证明产品取消/清理缺口，与测试首段输出等待不足分别处理。

## 实现行为

- 按项目共享初始化进程，改为逐调用者的可取消 continuation。取消一个等待者及时结束该任务，其他等待者继续使用原进程。
- 最后一个等待者取消时取消初始化并关闭 Agent；仅初始化 RPC 启用任务取消，普通 RPC 的响应等待语义保留。
- 失败/取消清理在未取消的任务中运行。未初始化进程直接进入终止步骤，已初始化进程的正常 EOF 退出方式保留。
- 保存全部未完成的启动/清理任务；关闭结束等待者并等待进程清理。每次启动有独立身份，旧清理不能覆盖同目录的新启动。
- 开始回合、开始准备及准备返回处检查取消，阻止已取消的调用者继续创建/提交回合。

## 本轮验证

修复通过 7 组共 **129 项**关联回归（`.cache/core-startup-related-regression.log`，283.519 秒）：

| 测试组 | 项数 | 范围 |
| --- | ---: | --- |
| CodexStartupCancellationTests | 4 | 启动中停止、无模型请求、队列/草稿保留、PID 退出及重试；共享启动取消一个等待者、另一任务完成且只有一个 Agent；关闭收尾；旧清理未结束时同目录立即重试 |
| ActivityArchiveTransportTests | 11 | 两种协议、五个归档入口及 6 秒延迟启动后真实流式归档 |
| ModelTransportTests | 86 | 会话、工具/补丁、审批/提问/MCP、计划/目标、图片/文件、队列/引导/停止、并行/独立窗口、恢复/审查及 Swift 修复/Git 闭环 |
| CodexNativeForkTests | 7 | 实际 Core 历史分叉、工作树、Handoff 与恢复 |
| CodexPlanDocumentTests | 3 | 计划文档记录及归属 |
| SkillDiscoveryTransportTests | 14 | 发现/读取、预算、依赖、启动失败及权限选择 |
| WorkspaceRestorationTests | 4 | 工作区恢复和状态隔离 |

新用例的停止/等待释放/关闭断言保持 2 秒上限，启动延迟仍为 6 秒；总耗时包含正常完成的存活任务或重试，不能当作取消耗时。实际模型请求数及进程退出都有独立断言。

审核又补齐旧启动已完成但失去归属时的同类清理边界：其关闭也置于未取消的任务中。最终源码的启动取消和归档 **15 项复测通过**（`.cache/core-startup-final-cancellation.log`，38.038 秒），与上述关联集重叠，不累加为 144 项不同用例。

`script/build_and_run.sh` 增加可选 `SHIPIOS_BUILD_CACHE_ROOT`，仅选择构建缓存，默认目录不变。全量测试仍占用默认缓存时，打包可执行文件、资源及 SwiftTerm 许可证均使用所指定目录：

```sh
SHIPIOS_BUILD_CACHE_ROOT="$PWD/.cache/native-startup-cancel" ./script/build_and_run.sh
```

正式构建运行退出 0，最终清理修正后再次通过（`.cache/core-startup-final-native-run.log`），最终严格深度签名通过（`.cache/core-startup-final-native-signature.log`），实际 Agent IPC 冒烟通过（`.cache/core-startup-ipc-smoke.log`）。README 过时的“Responses 全部只读”“工具待接入”说明已按当前实现纠正。

## 验收边界

Mac 仍锁定，新的正式应用工作区不能前台实操；启动命令成功、签名或进程存在不算可交互验收。正常初始化后的全部工具取消/断联组合、真实用户 API/GitHub 及 Codex 双端逐页验收仍未完成，完整配对保持 **0/47**。

针对旧提交 `f96b997` 的全量回归继续运行，已有第 602 篇记录的归档等待失败；129 项是修复后的关联集，不能替代全部 macOS 测试或将旧全量记为通过。全部新夹具使用临时目录和本机服务，不使用或输出外部 API Key。
