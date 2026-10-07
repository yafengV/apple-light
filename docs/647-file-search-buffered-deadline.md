# 文件搜索已读响应与超时顺序

日期：2026-10-07。接续第 646 篇。范围保持 21 类主窗口、26 类设置、29 项核心要求，完整双端配对 **0/47**。

## 失败来源与定位边界

第 643 篇固定提交 `21dad308b48ec4cfdc1f17c2216166fb014e92d4` 的完整回归已终态 exit 1：2,773 项 Swift、2 跳过、一个 unexpected failure。`WorkspaceFileSearchSessionTests.testPartialResultsKeepAWorkingSearchAlive` 在约 0.412 秒收到搜索超时，完整日志 `.cache/full-alignment-regression-643.log`；该 runner 未执行后续 IPC。

先保持旧测试二进制、helper、既有夹具和资源不变，单独重跑该用例六次，均 exit 0，结果 `.cache/file-search-baseline-repeats-647.json`。这表明原失败是间歇性现象，不证明其全部调度来源已定位。

本阶段确认另一条可确定复现的竞争：后台 `availableData` 已读到响应，但普通响应交付尚未在主线程执行；就绪的超时任务可先关闭会话。原先的 deadlineRevision 只保护已经处理过的进度，不能看见待交付的数据。

## 修复前证据

新增真实 shell 子进程、真实管道和受控 deadline/交付门控，不手写模拟解析结果、不提高生产超时、不依赖额外 sleep 窗口：确认实际响应已读后，挂起普通交付，让期限先检查会话。三项用例分别检查进度保留、完成优先、旧 ID 与协议错误。

原逻辑 **3 项、5 条失败（一个 unexpected）、exit 1**，日志 `.cache/file-search-buffered-baseline-647.log`：有效进度未交付、完成被报告超时、缓冲的协议错误被误报超时。此前首次测试草稿存在 XCTest async autoclosure 编译错误，日志 `.cache/file-search-buffered-before-647.log`，没有计入运行通过数量。

这证明已读数据/期限顺序存在缺陷；不据此宣称旧全量的 400 毫秒失败一定由完全相同的线程调度造成。

## 实现

- `WorkspaceFileSearchInbox` 通过锁保留后台实际读取顺序及 EOF；主线程从队列批量取出数据，所有解析、当前 ID 校验和 UI 状态仍在原 MainActor 作用域执行。
- 交付通知可合并为一个，数据本身不丢弃。512 个真实部分响应及最终完成逐条、按原序到达。
- 就绪期限先核验本查询/本期限资格，再处理已经读取的数据，随后重新核验资格。合法当前进度续期，完成取消期限；旧 ID、半截帧不能续期，错误帧仍报告协议错误，EOF 仍报告退出。
- 关闭/析构清理收件队列；迟到数据不能重新开启会话。既有查询替换、防抖、进程/索引复用和结果归属规则保留。
- 交付控制钩子只用于确定性测试，生产默认 nil，不增加异步等待。默认 20 秒超时及界面 75 毫秒防抖未修改。

本阶段依据第 633 篇已核对的公开参考保留会话/索引复用及结果归属，不宣称 Codex 使用相同线协议或超时算法。

## 验证

初轮 **42 项、0 失败/跳过、exit 0**（`.cache/file-search-associated-647.log`），之后增加持续静默仍超时及多帧顺序验证，并扩大外观/设置回归。中间 194 项通过记录 `.cache/file-search-final-associated-647.log`；将测试钩子改为生产默认关闭后，最终 **194 项、0 失败/跳过、65.528 秒、exit 0**，日志 `.cache/file-search-formal-final-associated-647.log`。集合重叠，不累加。

范围覆盖 WorkspaceFileSearch、文件/命令搜索、来源焦点、Appearance、设置导航、主题卡片/包内资源与设置返回焦点。五项新增用例覆盖读进度、读完成、进度后停滞、512 帧合并通知、旧 ID/协议错误。原部分进度 400 毫秒用例保留原值与五次真实输出。

补充四轮搜索会话组复测（每轮 13 项）日志 `.cache/file-search-current-repeats-647.json` 使用默认测试 helper，并非正式包精确 helper。最终正式 helper 的四轮结果另见 `.cache/file-search-formal-repeats-647.json`，不与 194 项累加。

最终标准构建/启动 exit 0，日志 `.cache/file-search-formal-final-run-647.log`；严格签名与 IPC 冒烟 exit 0，日志 `.cache/file-search-signature-final-647.log` / `.cache/file-search-ipc-final-647.log`。Core 冒烟首次因沙箱禁止本机监听而未启动（`.cache/file-search-core-rpc-final-647.log`），获准重跑后 exit 0（`.cache/file-search-core-rpc-final2-647.log`），实际验证审批、提问、引导、工作区写入、隔离和凭据清理。helper SHA-256 保持 `380bec2aac119df2c9755850f1aa6150dd14cb9403a2eb8d42eff39e7f54ae9b`。没有 Rust 源码变化，不新增 Rust 全套重跑结论。

## 前台、全量与剩余

本轮标准脚本使用默认数据目录；CUA 明确返回 Mac locked，自动解锁失败，已在第 646 篇请求用户手动解锁。本阶段没有新版本实际工作区、搜索弹层/来源焦点或外观分区验收；不将进程、构建或隐藏窗口测试称为前台可交互。

本轮提交后准备新的固定测试二进制/helper/夹具/应用与测试资源全量，清单和终态写入 `.cache/full-alignment-regression-647-manifest.json` / `-status.json`。新的完整回归未取得终态前，旧全量失败保持未消除，不写成全部功能或全部测试通过。

大项目延迟、所有文件打开/焦点边界、第 646 篇实际外观交互、字体平滑/Dock/VoiceOver、子任务其余权限/V2 恢复、审批偶发超时根因及其余矩阵范围保持。目标仍未完成。
