# 设置返回来源控件与焦点隔离

日期：2026-10-07。接续[第 634 篇](634-file-search-source-focus.md)。主窗口设置返回现保留原文件编辑器或页面输入控件；全产品范围仍为 21 类主页面、26 类设置、29 项核心要求，完整双端配对保持 **0/47**。

## 来源与实际问题

修复前在隔离数据根 `/private/tmp/shipios-ui-633/Data` 实际操作右侧 AlphaBeta.swift → ⌘, → Esc，文件仍在，但焦点转到了任务输入区。原 closeSettings 仅恢复页面并无条件请求聚焦输入区，没有保存原控件。

只读检查同一 Codex 26.930.51102 / build 13100 公开资源：settings-page-b07b6e77dc14.js，50,276 字节，SHA-256 808346c81f26865aa4f9eefad7f7d4599a6543f302bf706fc3533388f0526768；settings-route-state-4040f1d851b2.js，1,172 字节，SHA-256 e581124e9c9bd547b96d5593dd35845034b09a5bc8aeacacbb3ba26a6aa1f3ef。前者包含 onBack 和设置搜索/分类键盘焦点，后者定义 returnToPreviousHistoryEntry/workspaceRoot。它们支持返回来源的路由语义，不能证明全部原生来源焦点、动画或双端配对。没有读取个人配置、认证或历史。

## 实现

- 首次进入设置捕获主窗口来源控件；分类切换或重复 ⌘, 不覆盖快照。来源窗口优先选择 ID main，避免错误清空其他独立任务窗口。
- 文件来源通过弱引用的原工作区、root/path 和模型焦点请求恢复，兼容左右内容标签及旧文件详情面板。非文件控件沿用原生响应链恢复，并核验窗口、页面、任务/项目作用域。
- 命令菜单进入设置传递菜单打开前的来源，不把菜单查询框误当返回目标；搜索弹层直接打开设置也保留其来源。
- 未保存确认期间不恢复焦点；确认实际退出后才恢复。新的设置进入修订令牌使先前排队的非文件恢复失效。文件原生回调继续使用第 634 篇的页面/弹层/活动标签门控。

## 失败复现和自动验证

初轮旧行为 5 项测试共 11 条断言失败，日志 `.cache/settings-return-before-635.log`。命令菜单用例最初过早关闭设置，使旧文件回调恰好执行，属于不充分测试；改为在设置中先等待并断言原编辑器未聚焦，再关闭设置。旧代码最终 **5 项、12 条断言失败、0 unexpected、exit 1**，日志 `.cache/settings-return-ready-before-635.log`。没有删除失败断言。

新增 SettingsReturnFocusTests 共 7 个方法：左右/详情面板原生编辑器及选区保持；项目/插件/技能/自动化来源字段；命令菜单来源；未保存确认；文件变化或窗口失去资格；任务/项目变化；重复进入设置使旧恢复回调失效。使用真实 NSWindow、NSHostingView 和 AppKit 响应链，窗口 key 资格由测试子类控制；不等于全部实际前台操作。

第一组 84 项通过，日志 `.cache/settings-return-associated-635.log`。最终扩大回归 **140 项、0 失败/跳过、25.041 秒、exit 0**，日志 `.cache/settings-return-final-associated-635.log`，包含设置导航/确认/文本编辑、命令及文件搜索、文件标签/焦点、插件设置和终端焦点。两组重叠，不累加。

## 正式包与实际窗口

通过 `script/build_and_run.sh --app --data-root /private/tmp/shipios-ui-633/Data`，独立缓存 `.cache/native-ui-632`、Rust target `.cache/subagent-controls-target` 构建运行；Swift 3.22 秒、exit 0，日志 `.cache/settings-return-formal-run-635.log`。严格签名、包内 IPC 和 Core RPC 本机夹具均 exit 0，日志 `.cache/settings-return-signature-635.log`、`.cache/settings-return-ipc-635.log`、`.cache/settings-return-core-rpc-635.log`。本阶段没有 Rust 生产代码修改，也没有外部 API 请求。

实际 CUA 验证：

- 右侧文件 → ⌘, → 切换快捷键分类 → 再次 ⌘, → Esc，返回原文件内容并聚焦编辑器。
- 右侧文件 → ⌘K → 搜索“设置” → Return → 同窗口设置 → 点击“返回应用”，返回 AlphaBeta.swift，编辑器实际聚焦。
- 技能搜索输入 focus-635 → ⌘, → Esc，原查询保留；继续键盘输入 -return，值实际变为 focus-635-return，确认键盘归属原搜索框。

随后通过同一正式脚本恢复默认数据根。第一次沙箱内构建成功，但 Launch Services 返回 -10827，不能计为启动成功，日志 `.cache/settings-return-default-run-635.log`；使用已授权原生启动权限重跑 exit 0，日志 `.cache/settings-return-default-retry-635.log`。CUA 确认 other 工作区无持续 loading，可点击任务输入；⌘, 在 ID main 打开设置，Esc 返回 other 且原任务输入聚焦。未修改用户 API 凭据。

## 全量结果与剩余范围

第 631 篇固定提交 b1d3148 的全量本轮已终态 **exit 1**：Rust fmt/clippy/tests 通过，Swift **2,728 项、2 项跳过、一个用例共两条失败断言**，76 分钟。失败为 PullRequestCodeHeaderTests.testHiddenFileAndCommentLineNavigationSurvivesStickySectionsAndModeChanges 的评论行不可见和 scroll origin 12 不大于 500；日志 `.cache/full-alignment-regression-631.log`、状态 `.cache/full-alignment-regression-631-status.json`。该二进制早于第 632 篇定位及等待修正，不能当成当前代码失败，也不能因专项通过将旧全量改记为通过。连续进度搜索测试本次通过，仍不能证明先前 400ms 偶发超时根因已解决。

最新全量仍需取得终态。全部设置的精确呈现/交互、其他模态/窗口边界、真实模型及其余矩阵缺口保持未完成；上述实际操作不代替完整 Codex 双端逐页验收。
