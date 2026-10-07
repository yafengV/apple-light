# 失败与中断子任务的概览过滤及原线程重试

日期：2026-10-07。接续第 636/637 篇；47 类页面及 29 项核心范围不变，完整双端配对仍 **0/47**。

## 参考和实际问题

沿用已核对的本机公开 Codex 26.930.51102 / build 13100 资源副本 `.cache/closed-child-reference-636.js`，SHA-256 234429db84d9319850ff0766a4a5052a9e898bfa0611883633f80018080dd6c0。原函数 Let/Det 在运行时非 active 时隐藏 interrupted/errored，运行中的重试仍 active；systemError 也隐藏。提取原函数的 28 组状态/运行时组合记录于 `.cache/subagent-status-oracle-638.json`，不是 ShipiOS 全状态对齐测试。

旧正式包在真实 Core 子请求 HTTP 400 后，仍把失败 Laplace 列入“活动 · 1 / 1 个未运行”。前台实际看到此问题，隔离快照 `/private/tmp/shipios-ui-638/before-fix.json` 保留 failed。没有将该截图当作 Codex 双端证据。

## 变更

增加共用 SubagentOverview 投影：failed/interrupted/shutdown 不进入概览活动、完成或摘要入口。列表与摘要使用同一投影；全部隐藏时不残留摘要分隔线。任务原始子记录不删除，已打开详情继续保留历史、草稿和可用的重试输入。实际重试变为 Running 后重新列入活动，完成后进入已完成。

本阶段仅处理现有原生终态的过滤，不替代参考完整的 runtime/discovery/冷加载状态投影。未修改 Rust、Core 或依赖。

## 自动验证

新增本机 Responses 夹具及三项实际 Core 集成，覆盖 HTTP 400、实际停止子回合、失败后关闭应用存储并冷恢复。验证原生终态、概览隐藏但持久记录保留、文字草稿和历史保留、同一 child/thread 的真实续聊、父 runIDs 与父回复不变。重试单独设门，实际观察 Running 重新进入活动，再释放回复观察 completed，避免瞬时回复跳过活动断言。

初次两项通过，扩展后最终关联集合 **142 项、0 失败、51.111 秒、exit 0**，日志 `.cache/subagent-states-final-associated-638.log`；集合之间重叠，不累加。最终测试使用第 637 篇签名正式 helper，SHA-256 bb0215ed9a87f350fcb865bdf761b926a3f471061a37f69e8dce2aad5a6ea47d，与本阶段正式包一致。没有新的 Rust 全套测试结论。

## 原生可见验证

通过 `script/build_and_run.sh --app --data-root /private/tmp/shipios-ui-638/Data` 构建运行，正式 Swift 构建 2.84 秒，日志 `.cache/subagent-states-formal-run-638.log`。仅使用 127.0.0.1:63222 自有夹具，Key 留空。原冷失败任务显示活动 0、无完成条目，摘要没有子任务入口。

新失败任务 9593345C-C9B6-4E82-9B8F-F5AA29DDAD9F，子 01a11509-cc8f-751a-a21f-5d02fc13e703（Gauss）：父先完成、子仍运行；详情输入“state-child-retry 保留失败草稿🙂”，释放 HTTP 400 后草稿仍在、停止消失、发送可用，详情不被过滤关闭，摘要无子任务入口。发送得到 Child recovered on the same thread，草稿清空，活动 0 / 已完成 1。

新中断任务 53B49AAA-6835-4F32-9EE1-7E0F300BB41D，子 01a1150a-8848-7312-918f-bf4f61284a2f（Euclid）：真实点击停止子任务，原草稿“state-child-retry 保留中断草稿🙂”仍在，摘要无子任务入口。原位发送得到同一子线程回复，返回列表实际看到活动 0 / 已完成 1。最终隔离快照 after-both-retries.json 确认两个子 ID 未变、completed，两个父任务各只有一个 runID。

前台使用即时重试回复；自动测试另覆盖阻塞重试期间的活动投影。原生截图/可访问性结果与隔离运行数据均不进入 Git。

最后使用正式脚本恢复默认数据根。首次恢复使用默认 Rust 构建目录额外编译 2 分 18 秒；随后用已验证的 `.cache/subagent-controls-target` 再次运行正式脚本，Swift 构建 4.50 秒、exit 0，日志 `.cache/subagent-states-final-default-run-638.log`。实际看到默认新任务及原 `/local` 草稿，无持续 loading；点击输入后 ⌘, 在 ID main 打开设置，Esc 返回原草稿并恢复输入焦点。严格签名通过，最终 helper 与测试精确副本 SHA 相同，日志 `.cache/subagent-states-signature-638.log`、`.cache/subagent-states-restored-agent-shas-638.log`。固定最终 helper 的 IPC 及 Core RPC 冒烟均 exit 0，日志 `.cache/subagent-states-ipc-638.log`、`.cache/subagent-states-core-rpc-638.log`。本机前台夹具正常 Ctrl-C 停止。

## 尚未完成

第 635 篇固定全量原 handle 30966 本轮重新确认仍 live，没有终态；固定输入不覆盖第 636—638 篇，不重启或改写冻结缓存。其他子任务状态/权限/提问、完整输入及 V2 恢复、排序/头像/摘要、真实用户服务、全部页面和交互双端配对仍需继续。
