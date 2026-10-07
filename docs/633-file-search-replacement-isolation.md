# 文件搜索替换查询隔离

日期：2026-10-07。接续[第 632 篇](632-pr-delayed-navigation.md)。本阶段修复查询替换期间旧期限关闭共享索引进程的问题，完整双端配对仍为 **0/47**。

## 参考与实现

本机 Codex 26.930.51102 / build 13100 的公开 app-initial-f9b16fbf8fc7.js（11,173,718 字节，SHA-256 22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3）中，QOc/ukc 保留会话并更新查询，根或宿主变化时停止旧会话。缓存 `.cache/search-reference-initial-633.js`，没有读取个人认证、配置或历史。这支持索引复用和结果归属，不证明防抖时长或线协议完全相同。

ShipiOS 原先在替换查询时更新界面身份，再等待 75 毫秒；这段期间旧传输期限仍可关闭共享进程，导致新查询报告“文件搜索进程不可用，请重试”。现先取消旧查询及期限，再进入新查询防抖；索引进程保留。空查询沿用已有取消路径，根/重试/执行文件变化仍重建会话。没有更改 75 毫秒防抖或默认 20 秒期限。

## 复现与验证

新增真实 Python 子进程测试，先观察 helper 接受 first，再启动 next，在新查询防抖期释放旧期限；核验无错误、Next.swift、同一个 PID/一次索引创建及实际查询日志 first → 空查询 → next。没有仅模拟界面结果。

初次测试未等待 helper 就绪，1 项出现三条失败记录，其中一条为查询日志尚未创建；日志 `.cache/search-replacement-before-633.log`。补齐实际就绪观察后的旧实现仍失败：1 项、三条断言失败、0 unexpected、exit 1，日志 `.cache/search-replacement-ready-before-633.log`；结果为空、进程不可用且只记录 first。

修复后 **39 项关联、0 失败/跳过、4.310 秒、exit 0**，日志 `.cache/search-replacement-associated-633.log`。覆盖搜索目录/会话、文件/命令弹层、命令菜单及浏览器搜索。使用独立 `.cache/native-ui-632/macos-build` 和固定 Agent，不覆盖正在运行的旧全量测试二进制或既有 Fixtures。

通过 `script/build_and_run.sh --app --data-root /private/tmp/shipios-ui-633/Data` 构建运行正式包，Swift 2.75 秒、exit 0；日志 `.cache/search-replacement-formal-run-633.log`。严格签名、包内 IPC 和 Core RPC 冒烟均 exit 0，日志分别为 `.cache/search-replacement-signature-633.log`、`.cache/search-replacement-ipc-633.log`、`.cache/search-replacement-core-rpc-633.log`。没有 Rust 源码变化，不新增 Rust 全套重跑结论。

## 实际前台与剩余

隔离项目包含 AlphaBeta.swift、Next.swift、目录/中文文件🙂.txt。实际 ⌘P 后 ab 找到 AlphaBeta.swift，n 替换为 next 找到 Next.swift；Return 打开真实内容 `let next = 2` 并聚焦编辑器。再次搜索中文显示中文文件；清空后候选清除并显示输入提示，Esc 保留原文件内容。两次连续 setValue 中一次遇到工具元素 ID 失效，刷新后继续；不将它算成应用错误或原子快速查询验证。

上述 Esc 返回后焦点落到窗口，而非来源文件编辑器，属于尚未修复的实际缺口，下一阶段继续处理。随后通过同一正式脚本恢复默认数据根，Swift 0.16 秒、exit 0（`.cache/search-replacement-default-run-633.log`），CUA 确认 other 工作区可交互且没有持续 loading。本阶段没有新增默认设置往返的验收结论。

第 631 篇固定全量经原 handle 77140 再确认仍运行，不覆盖第 632/633 篇。第 627 篇旧全量中的连续进度 400 毫秒超时尚未根因定位，不能用本次不同竞争的修复宣称已解决。大项目延迟、全部文件打开/焦点组合、真实 Codex 双端页面及其余矩阵仍未完成。
