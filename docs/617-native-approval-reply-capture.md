# 原生子任务审批的请求绑定

接续[第 616 篇](616-native-subagent-live-events.md)。本阶段为子任务的可操作审批增加原始等待请求绑定，尚未接入 Agent 请求令牌、RPC 或 Swift 审批按钮，不记为子任务审批 UI 已完成。完整目标和[29 项核心、47 类页面矩阵](599-core-function-parity-matrix.md)保持不变。

## 为什么需要 Core 补丁

固定版本 `50d77959bf927293c4b5ddcca81d05331ae582ea` 的 `handlers::exec_approval` 使用可选回合 ID 作为事件关联，实际 `notify_approval` 按调用/审批 ID 取当前回合的等待通道；`Abort` 直接中断当前回合。先查询活动回合再提交普通 Op 仍存在竞争。模型可重复调用 ID，因此不能把迟到的子审批响应按 ID 发送给新请求。

当前 Extension API 的人工审批路径不调用 ApprovalReviewContributor；强制改成自动审核会改变用户审批策略，不能用它伪装成同等行为。本阶段引入固定版本的 Core 本地 Cargo patch，其他上游组件继续使用同一 Git revision。保留上游许可、NOTICE、README、资源与测试，实际运行时差异只有四个文件；[可审查补丁](../upstream/codex-core-approval-capture.patch)和[组件说明](../vendor/codex-core/README.md)记录边界。

## 已实现

| 内容 | 实现及边界 |
| --- | --- |
| 请求实例 | 原生命令/补丁审批注册前产生单调 Unix 毫秒戳；同调用 ID、同回合也不会命中旧实例。高频请求可能使戳略领先墙钟；协议字段形状不变 |
| 原始回复 | `CodexThread.claim_approval_for_turn` 在活动回合锁内检查回合、有效审批 ID、时间戳并只允许认领一次，返回不可复制的 `CapturedApproval` |
| 子树归属 | ShipiOS `DescendantSource.claim_approval` 先验证真实任务子树，拒绝根线程、无关线程、冷/未加载线程及无效身份；不装载冷线程 |
| 取消所有权 | Core 仍持有等待单元；取消、清理、覆盖关闭原始 sender，即使宿主持有能力也不会悬挂等待。宿主丢弃能力亦关闭原等待 |
| 回复行为 | 回复直接投递原始 sender，不查找同 ID 的替代请求。普通按 ID 回复不能履行已认领通道。重复认领、错回合/ID/实例和迟到回复被拒绝 |
| 终止 | 显式 Abort 调用现有按回合保护的原生中断，不停止其他子线程或新回合；丢弃通道保留原生等待取消行为，与显式整回合 Abort 区分 |
| 持久授权 | 有效前缀审批在原回合锁内应用原生规则及警告行为；取消后的旧能力不写策略。宿主后续仍需校验原生 available_decisions，不自行发明用户选项 |
| 测试入口 | `script/test.sh` 先构建真实 Agent 并设置 SHIPIOS_TEST_AGENT，再运行 Rust 和 Swift；真实执行测试需要其隐藏 exec-server 模式 |
| 可复现审计 | `script/verify_codex_core_patch.py` 对固定 Git 版本、四文件 patch 回放、其余 781 文件、独立 Cargo 依赖/feature 合并及许可作核对；Python 3.11+，上游 checkout 由参数提供 |

Core 被排除出 ShipiOS workspace，`cargo test --workspace` 不运行上游完整 Core 私有单元/集成测试；本阶段新增测试经公开 API 驱动实际 Core。源码审计不代替行为验证，固定 HTTP 回答不证明真实模型自主编码或委派。

## 验证记录

- 首次 Core 检查发现多余泛型括号，已修正；新增拒绝夹具两次编译使用了错误的 Denied 变体，最终使用原生 `ReviewDecision::denied`。失败记录保留，不计通过。
- 最初三项真实 Core 子线程验证通过。扩大到补丁审批时，临时目录原本属于允许写入的范围，因此没有触发审批而超时。改为显式只读沙箱，不改变生产权限；随后五项通过。
- 最终六项原生验证通过，0 失败/忽略，1.47 秒，`.cache/subagent-approval-native-tests6.log`：精确认领与真实命令执行；跨回合重复 ID 与旧策略修改拒绝；一个子任务 Abort/另一个仍等待及丢弃通道；同回合重复 ID；补丁只在批准后写入；原生前缀规则实际持久化与执行。
- Rust workspace 最终 **182 项通过，0 失败/忽略**，terminal exit 0，`.cache/subagent-approval-rust-final.log`。含六项新增与现有停止/子孙/历史/Hook/IPC/配置隔离；不代表上游 Core 全套测试。
- 独立 manifest/源码审计通过，固定上游 **781 个文件**，仅四文件运行时 patch，`.cache/subagent-approval-source-audit2.log`；Cargo.lock 只移除被路径替换的 Core source，不更新其他版本。
- 严格 workspace fmt、四个 Core 源文件的 rustfmt 检查及 workspace 全 target Clippy `-D warnings` 通过；`.cache/subagent-approval-clippy.log`，terminal exit 0。此检查范围不等于上游 Core 全套测试。
- 新 Agent 的 **76 项 Swift 关联回归通过，0 失败/跳过**，155.194 秒，terminal exit 0，`.cache/subagent-approval-swift-associated.log`：根审批、补丁、提问、MCP 审批/表单/URL、原生分叉、启动取消、后台终端、Hook、真实子任务、详情和实时合并。Swift 源码未变化，使用第 616 篇最终编译的隔离测试包及当前新 Agent；没有把旧 Agent 的结果算作本阶段。
- 正式 `script/build_and_run.sh` 构建/签名/LaunchServices 启动 exit 0，Swift 构建 2.70 秒，`.cache/subagent-approval-app-run.log`。实际前台检查返回 Mac 锁定、自动解锁失败，不能确认工作区可交互或声称前台验收完成；完整配对 **0/47**。
- 正式包严格深度签名验证 exit 0，`.cache/subagent-approval-signature.log`。包内真实 IPC 冒烟和 Core 审批/补丁/提问/引导/写入/隔离/凭据清理冒烟均 exit 0，`.cache/subagent-approval-ipc-smoke.log`、`.cache/subagent-approval-codex-smoke.log`。
- 提交范围检查排除了缓存、构建产物、运行数据和个人凭据。完整 staged whitespace 检查报告六处统一 patch 的空白上下文行，以及四处原封保留的上游 Markdown 行尾/末尾空行；源码审计已确认其上游字节一致。自有变更与四个修改的 Core 源文件 whitespace 检查通过，不为了消除报告而修改上游资源。
- 第 616 篇的保留全量 handle **77058** 已重新核对仍在运行，日志推进到 GitPullRequestWorkflowTests；编译源码仍属 `d84d0f9`，不覆盖本阶段 Core 补丁，不能记为最新全量通过。

## 下一步与仍缺

1. Agent 为实际子事件认领原始审批，建立不可复用请求令牌；按所属父任务/子线程/回合验证 RPC，暴露实际原生选项，清理完成/取消/断开后的请求。
2. Swift 子详情显示可操作命令/补丁审批，支持失败保留、过期禁用、重复点击、窗口焦点和完整键盘；根回复和子草稿保持各自归属。
3. 结构化提问、权限请求和 MCP elicitation 各自的原始等待绑定、类型化表单及取消/过期行为。
4. 子任务全部工具/附件、单独停止、冷恢复、精确布局及前台、多窗口、双端完整配对；其他矩阵缺口继续逐项完成。

后续第 618 篇复核发现：本篇 76 项中的六项 ModelTransportTests 显式使用默认 target/debug Agent，不遵循 SHIPIOS_TEST_AGENT。因此它们的通过证明该版本 Swift 与旧 helper 的行为，不能算本篇新 Core 的完整后端证据；其他关联组及正式包 Core 冒烟的记录保持。第 618 篇把六项入口改为显式发现指定 Agent 并单独重跑，以实际新/包内 helper 确认后端来源。
