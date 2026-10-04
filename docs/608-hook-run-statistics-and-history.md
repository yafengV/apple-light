# 会话 Hook 统计与运行历史

接续[原生插件 Hook 环境](607-native-plugin-hook-environment.md)。真实 Agent 已转发 Hook 事件，但此前聊天界面忽略这些事件，没有运行统计入口。本阶段将它们接到回合历史及所属窗口内的统计弹层，覆盖实际 Core、持久化及原生控件。完整页面双端配对仍未完成。

## 参考与逐项对齐

参考本机公开应用资源版本 26.930.21537，读取 `local-conversation-turn-b96a8cfaa2c2.js` 的统计聚合、`user-message-9c53aabca701.js` 的入口、`hook-stats-dialog-13e46795f621.js` 的内容、`hooks-settings-model-f200bbc1bcb6.js` 的来源分组及 `hooks-a471dfd2b59d.js` 的图标。没有读取个人账户、配置、认证或会话，也没有操作 Codex 自身前台。公开资源支持以下行为核对，不能替代实际两侧页面验收。

| 内容 | 本阶段行为 | 证据/边界 |
| --- | --- | --- |
| 入口 | 已结束回合底部操作行显示 Hook 图标；仅有 running 或没有记录时不显示；阻止/失败使图标呈警告色 | AgentRun 统计与实际 Core；主窗口和独立任务窗口共用 ExecutionMessageView |
| 三项计数 | 运行次数包含所有已结束调用，阻止只计 blocked，失败只计 failed；stopped 和未知状态不错误计为失败 | 统计测试与实际阻止/失败事件 |
| 重复调用 | 同一 wire Hook ID 的多次调用保留独立展示 ID；started/completed 更新同次调用，重复完成不重复计数，迟到 started 不回退终态 | 重复调用、重复通知及恢复测试 |
| 顺序 | 保留运行历史的收到顺序，不按事件名称或配置顺序重新排序 | 对照参考聚合，不用 display_order 擅自重排历史 |
| 回合归属 | 有 turn_id 的迟到事件查找原回合；核对 task/thread，另一回合不能接收它；无 turn_id 的会话事件归入当前最新回合 | 历史隔离测试与实际 SessionStart |
| 持久化 | 保存到该 AgentRun 的 result，保留回复、其他结果和原生回合边界；重启恢复统计 | 实际 Store→Agent→Core→shell/HTTP→保存→恢复 |
| 来源 | 插件、用户、项目、会话、管理员、未知；系统/MDM/各管理配置统一管理员 | 对照参考来源分组；实际插件来源，其余为协议/模型测试 |
| 内容 | 状态、事件名和来源；默认全部折叠，多行可同时展开；展示非空 statusMessage | 原生 NSButton 展开与状态模型 |
| 输出 | warning 为消息，feedback 为反馈，error 为错误，stop 为停止原因；纯文本保留换行、可选择复制 | 原生长输出与模型测试；不进行 Markdown 解释 |
| context | 持久记录保留原生数据，但统计聚合过滤 context 及未知输出 kind，遵循参考；context 仍进入真实模型请求 | SessionStart/UserPromptSubmit/PreToolUse/PostToolUse 实际执行；HTTP 请求含上下文 |
| 无输出 | completed 不显示空理由；blocked、failed、stopped/未知分别显示对应缺省说明 | 状态模型和原生展开 |
| 弹层 | 覆盖所属窗口整个内容区域，680 点宽，最高 min(92% 窗口高, 800 点)，窄窗口收缩；主/独立窗口使用同一宿主 | WindowDialogHost；宽窄原生隐藏窗口，不创建 sheet 或新窗口 |
| 键盘与归属 | 初始焦点关闭；Tab/Shift-Tab 在关闭、历史滚动和各摘要按钮间移动；Return/Space 激活按钮；Esc/⌘W 关闭当前弹层；保留文本选择与复制 | 原生宿主及控件；实际前台按键/返回焦点仍需验收 |
| 动态更新 | 开着的统计可更新，保留已展开项和同 ID 的摘要按钮；原回合被移除/重新运行时失效 | 原生更新/控件身份测试；整个消息视图移除会拆除宿主 |

参考的 UI 聚合不会把所有 Hook 的全部 stdout 直接展示。原生 Stop hook 的非 0/2 退出返回 `hook exited with code N` 错误，并不把 stderr 自动当成显示消息；测试保留这个原生行为。

## 异步边界

锁定的 Core `hook_runtime.rs::should_emit_hook_notification` 明确只发送非 builtin 且 execution_mode 为 Sync 的 UI 事件。真实 async UserPromptSubmit 在后台执行，并于下一轮安全边界将结果放进请求；本阶段验证这条真实路径，同时验证 UI 没有凭空产生 async 统计。不能把“没有异步记录”误报为未执行，也不能宣称当前统计包含所有异步运行。

宿主的 Hook 回调放在响应流存在性检查之前，已知 task/thread/turn 的迟到通知仍能更新历史。核心自动化验证分清原生执行与注入迟到事件的状态测试；状态测试不等于上游在该场景发送了通知。

## 验证记录

初次构建时文件在编译过程中修改，编译器拒绝该次构建；随后修正 Coordinator 的 MainActor 隔离。普通沙箱首次不能启动本机 HTTP 夹具，获准环境下重新运行。首次真实 Stop 测试错误期待非 0/2 退出的 stderr，依据 Core 原始输出规则修正断言。首次 async 测试错误期待 UI 事件，已核对上述 Sync 限制并验证真实上下文执行，未伪造事件补齐断言。失败日志保留，不算通过。

- 关联回归 **125 项通过，0 失败/跳过**，262.786 秒：7 项统计、7 项原生分叉、4 项启动取消、12 项 Hook 设置、86 项模型传输及 9 项 Hook catalog。日志 `.cache/hook-stats-related-regression.log`。该批在最终键盘/颜色与活动流线程校验修正之前，不能说它覆盖所有最终修正。
- 新增真实 stdio 夹具，模拟回合结束后、另一回合运行中收到完成；重复完成，以及另一 task、错误 thread（使用当前回合 turn ID）均不会污染历史。它是协议边界测试，不冒充上游实际 async 通知。实际 Core 的执行另由上述同步与 async 上下文用例验证。
- 正式捆绑 Agent 的最终复测 **24 项通过，0 失败/跳过**，37.096 秒：8 项统计、12 项 Hook 设置和 4 项启动取消。覆盖最终线程校验、统计、宽窄原生控件与键盘修复。日志 `.cache/hook-stats-final-bundled-tests.log`。与 125 项重叠，不相加计算总测试数。
- 早期捆绑复测共 23 项、4 个断言失败：NSScrollView 将第一响应者转交 clip view，导致 Tab/Shift-Tab 与显式模态焦点列表不一致；现由历史滚动控件保留自己的焦点。宽窄图像还发现误用了不存在的次级文字颜色角色，深色下变黑，已改用 `textForegroundSecondary`；修复后复测及图像检查通过。失败记录 `.cache/hook-stats-bundled-tests.log`，修正记录 `.cache/hook-stats-focus-repair.log`。
- 隐藏窗口输出 `.cache/hook-stats-render/hook-stats-1000.png` 与 `hook-stats-420.png`；控件验证关闭初始目标、Tab/Shift-Tab、Space 展开、Esc/⌘W 关闭、多个独立展开、更新后按钮身份、长输出滚动与窗口模态归属。这些图像和操作都不等于真实前台/双端配对。
- 最终源码通过独立缓存的 `script/build_and_run.sh` 构建与 LaunchServices 启动、严格深度签名；日志 `.cache/hook-stats-release-app-run.log`、`.cache/hook-stats-release-signature.log`。实际前台工具返回 Mac 锁屏、自动解锁失败，没有取得工作区可交互或本阶段统计弹层的前台证据。
- 最终包内 Agent 的实际 IPC 冒烟 exit 0，涵盖诊断、事件、重放、报告、日志、立即重跑、构建取消、重启持久化及帧限制；日志 `.cache/hook-stats-release-ipc-smoke.log`。
- 本阶段不修改 Rust 代码；已有 167 项 Rust 通过记录见第 607 篇，没有把旧 Rust 结果包装成新一轮测试。
- 保留的全量 session 21812 已重新确认仍运行；覆盖 `f274f79`，日志 `.cache/full-alignment-regression-607.log`。它不覆盖第 608 篇 Swift 修改，不能宣布最新全量通过。更早 `f572ecf` 的全量 exit 0 与两项语音夹具跳过仍按第 607 篇保留。

## 仍需完成

- 本阶段弹层的实际前台打开、选择/复制、滚动、Tab/Shift-Tab、关闭后焦点，以及同版本 Codex 双端配对。
- PermissionRequest、Compact、Interrupt、Subagent、SessionEnd 完整运行/通知收尾，运行中即时停用，其他来源与 MCP/超时/错误隔离的完整矩阵。
- 原生 Core 本身隐藏的 async/builtin 通知不能用人工统计冒充；完整生命周期审计是另一明确验收项。
- 插件原始清单兼容性、大包性能、真实用户 API/GitHub 和所有其他页面缺口。

完整配对维持 **0/47**，29 项核心要求各自的剩余边界仍有效；以[完整矩阵](599-core-function-parity-matrix.md)为准。
