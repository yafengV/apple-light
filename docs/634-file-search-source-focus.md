# 搜索返回文件焦点与迟到请求隔离

日期：2026-10-07。接续[第 633 篇](633-file-search-replacement-isolation.md)。修复前台已经发现的文件内容标签搜索返回焦点缺口，并处理相邻操作的原生异步竞争。全产品对齐范围保持，完整双端配对 **0/47**。

## 依据与边界

第 633 篇实际从 Next.swift 内容标签打开 ⌘P、Esc 返回后，文件仍在但焦点落到主窗口。原 restoreOverlayFocus 只恢复右侧旧文件预览，否则请求聚焦任务输入区，忽略内容标签编辑器来源。

另读取同一 Codex 26.930.51102 / build 13100 的公开 command-menu-dialog-d83c5f5e2a79.js，48,290 字节，SHA-256 c445daf8e43f3f0d455fbca891ab8752ad240be365fb8494224341f54f430bcb，缓存 `.cache/file-search-focus-reference-634.js`。zi/Bi 捕获来源元素，特定 canvas.prompt/toggleFileTreePanel 操作关闭菜单后尝试聚焦仍连接的来源，并带来源面板分发。这是来源焦点语义的有限依据，不能证明文件搜索 Esc 的全部参考端行为；没有取得 Codex 双端前台配对，也未读取个人配置或认证。

## 修改

SearchDialogReturnFocus 额外弱引用原文件工作区并记录 root/path。搜索结束时在同一页面、原窗口有效且可聚焦、无 sheet、文件身份和当前命令文件工作区匹配时，向原模型发出新 fileFocusRequest；编辑器重建也能接受请求，不强持有旧视图。非文件设置输入仍使用现有控件恢复，旧右侧预览路径保留。

第一轮修复后再验证连续操作，真实原生回调仍会抢走已替换的搜索框焦点。FileSourcePreview 现在在异步回调执行前，再核验 ID main 的页面、弹层、确认和 Appshot 状态及活动文件标签。独立文件窗口继续按自己的 key-window/sheet 资格处理，不受主窗口设置和弹层门控。没有把焦点状态复制为第二套编辑器模型。

## 失败复现与最终测试

最初调用因编译器默认模块缓存不可写未执行测试，改用仓库内缓存。初版夹具还错误覆盖不支持文件标签的 bottom 位置，2 项共 14 条失败记录；修正为实际支持的 left/right 后，旧生产逻辑稳定产生 **2 项、30 条断言失败、0 unexpected、exit 1**，日志 `.cache/file-search-focus-ready-before-634.log`。原生 source first responder 与模型请求/输入区隔离断言均保留。

第一轮生产修复 **63 项关联通过**，日志 `.cache/file-search-focus-associated-634.log`；扩大连续操作测试又实际失败，**3 项、三条断言失败、0 unexpected、exit 1**，日志 `.cache/file-search-focus-pending-before-634.log`，分别为新搜索弹层、新聊天标签和设置页被迟到焦点请求抢走，不能将第一次通过视为最终代码通过。

最终 **83 项、0 失败/跳过、22.923 秒、exit 0**，日志 `.cache/file-search-focus-final-associated-634.log`。包含命令菜单/浏览器搜索、命令和文件弹层、文件内容标签、预览焦点、编辑及文件搜索会话/索引。新增 4 个方法覆盖：

| 隐藏原生窗口场景 | 检查 |
| --- | --- |
| left/right × 文件/命令/任务搜索 × 编辑器保留/重建，共 12 组合 | 原编辑器/新编辑器真实 first responder、选区保持、请求更新、任务输入区未获新请求 |
| 恢复前变更文件/活动标签/窗口资格/弹层/页面 | 不向旧文件请求焦点，不成为原生 first responder |
| 恢复后、回调前切换弹层/标签/页面 | 新文本框共享 field editor 继续保持焦点 |
| 独立文件窗口、主窗口正在设置搜索 | 独立编辑器仍可接收自己的焦点请求 |

这里使用真实 NSWindow、NSHostingView 和 AppKit 响应链；窗口 key 资格由测试子类控制，来源快照显式传入。它不替代真实前台或完整应用跨窗口验收。

## 正式包与实际前台

通过项目脚本使用独立缓存构建运行最终包：`SHIPIOS_BUILD_CACHE_ROOT="$PWD/.cache/native-ui-632" CARGO_NET_OFFLINE=true CARGO_TARGET_DIR="$PWD/.cache/subagent-controls-target" ./script/build_and_run.sh --app --data-root /private/tmp/shipios-ui-633/Data`，Swift 3.34 秒、exit 0，日志 `.cache/file-search-focus-final-formal-run-634.log`。严格签名、包内 IPC、Core RPC 本机夹具冒烟均 exit 0，日志 `.cache/file-search-focus-signature-634.log`、`.cache/file-search-focus-ipc-634.log`、`.cache/file-search-focus-core-rpc-634.log`。本阶段无 Rust 源码修改，不新增 Rust 全套重跑结论。

CUA 确认最终包可交互，所有操作都在自己的隔离数据根：

- Next.swift 编辑器 → ⌘P → Esc，返回文件编辑器焦点。
- Next.swift 编辑器 → ⌘K → Esc，以及侧栏任务搜索 → Esc，均返回文件编辑器焦点。
- 搜索 ab → Return，打开真实 AlphaBeta.swift，内容 `let alpha = 1`，新文件取得焦点，没有回到 Next.swift。
- 将 AlphaBeta.swift 移到右侧面板，⌘P → Esc，以及 ⌘P → 点击取消，两者均恢复右侧编辑器焦点。

标签按钮的 AX 右键点击两次报告 offscreen，之后按可见截图位置打开上下文菜单；菜单通过已暴露 Cancel 动作关闭，随后实际选择“移到右侧面板”成功。上述工具路由问题不计应用缺陷，也不将最初失败点击记为成功。

最后再次通过正式脚本恢复默认数据根，Swift 0.16 秒、exit 0，日志 `.cache/file-search-focus-default-run-634.log`。CUA 确认 other 可交互且无持续 loading；⌘, 在同一个 ID main 打开设置，Esc 返回 other 且任务输入重新聚焦。

第 631 篇固定提交/测试二进制的全量经原 handle 77140 确认仍运行，进程链 runner 98811 → Swift 5874 → xctest 6153 存活；其缓存和既有 Fixtures 未修改，不能用它覆盖第 632—634 篇。本阶段没有修复旧连续进度搜索超时，也没有完成 Codex 双端、所有设置/编辑器/远程或其他矩阵缺口。
