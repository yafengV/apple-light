# 工作区搜索取消与结果选择的焦点归属

日期：2026-10-07。接续[第 653 篇](653-settings-main-window-selection.md)。本阶段补齐工作区搜索取消后的原控件恢复，以及选择已有文件后的编辑器聚焦。完整双端配对仍为 **0/47**。

## 问题与参考边界

原 `restoreOverlayFocus` 在工作区只识别文件编辑器来源，其余来源统一改写父聊天输入区的焦点请求。保存了终端、子输入器或其他工作区字段的来源快照，也不会使用。搜索入口还直接使用进程全局 key window，与设置入口已验证的活动主窗口选择不同。

本轮复核第 634 篇保存的公开 `command-menu-dialog-d83c5f5e2a79.js`，SHA-256 `c445daf8e43f3f0d455fbca891ab8752ad240be365fb8494224341f54f430bcb`。`zi` 捕获活动元素，`Bi` 对部分命令恢复仍连接的来源并保留来源面板。这是来源归属语义的有限证据，**不能证明 Codex 四种搜索取消、选区或所有窗口的具体行为已经配对**。本轮没有操作参考应用前台、读取个人配置或认证。

## 实现

- 设置和主窗口搜索共用活动、可见、其余 `main` 窗口及最后 key-window 回退顺序。首次搜索捕获原控件；在搜索模式间切换时保留该来源和文件上下文。
- 主窗口来源快照记录任务归属和项目根。取消搜索时恢复仍有效的原字段、终端或输入器；子输入器使用已有 coordinator 等待实际重新启用。已经失效或移除的来源不会改为请求父聊天输入区。
- 搜索入口及新模态生成新的焦点版本；延迟恢复再次核验版本、页面、任务/项目和模态状态，防止旧关闭回调抢走新输入。
- 原生文本框共用 field editor，重新成为 first responder 时 AppKit 会默认全选。快照保存原选区和仅在内存使用的内容指纹，值未变才恢复选区；不额外保存字段内容，安全文本框不参与该选区快照。
- 文件搜索取消显式走 `cancelFileSearch`；选择结果走 `openFileSearchResult`。移除主页面对文件搜索关闭的一律恢复，以免导航也恢复旧来源。成功选择会清理旧来源、隔离旧回调并向目标文件请求焦点，已经打开的文件也适用；无效或迟到选择不会关闭其他弹层。

## 失败复现和测试

独立使用 `.cache/native-ui-654`，没有改动正在运行全量所用的 `.cache/native-ui-648`。初次克隆的模块缓存因绝对路径不一致报 PCH/SwiftShims 错误，未执行测试；保留旧副本并在新路径重建生成目录后继续。

旧生产逻辑的新增 5 个方法产生 **35 条断言失败、0 unexpected，7.296 秒，exit 1**，日志 `.cache/search-return-repro-654.log`。其中来源返回测试显式提供快照以隔离 AppKit 全局 key-window 查找，独立入口测试则不注入快照。最终测试已全部使用实际 `setOverlay` 捕获入口。

第一轮修复后新增终端方法，共 6 项仍有 5 条失败：四种弹层返回字段时默认全选，以及隐藏夹具把查询框一并隐藏。前者补充生产选区恢复；后者改为只隐藏来源控件，保留可见查询框和原焦点断言。日志 `.cache/search-return-fixed-654.log`。

修正后 35 项关联 **0 失败/跳过，19.771 秒**，日志 `.cache/search-return-associated-654.log`。继续处理文件结果导航后扩大到 **70 项、0 失败/跳过，30.486 秒**，日志 `.cache/search-return-expanded-654.log`。集合重叠，不累加。

新增 `WorkspaceSearchReturnFocusTests` 最终 9 个方法覆盖：

| 场景 | 原生检查 |
| --- | --- |
| 命令/任务/文件/项目选择四种弹层取消 | 原字段 first responder、UTF-16 选区、中文值保持，父输入请求不变 |
| 四种弹层返回被暂时禁用的子输入器 | 等待重新启用，原 first responder、选区和中文草稿保持 |
| 任务、项目、页面、新搜索/预览、非活动窗口、隐藏/移除来源 | 查询框保持焦点，不改写父输入请求 |
| 工作区和技能页连续重新进入搜索 | 旧字段不重新获得共享编辑器，最新字段恢复 |
| 两个主窗口候选及搜索模式切换 | 捕获活动来源，原来源不会变成查询框 |
| 四种弹层返回真实 `SessionTerminalView` | 终端重新成为 first responder，父输入请求不变 |
| 从终端选择已经打开的文件 | 文件编辑器获得真实 first responder，旧终端不抢回焦点 |
| 无效路径、其他弹层中的迟到结果/取消 | 原搜索保持且可取消，不关闭其他弹层 |
| 搜索期间来源字段值更新 | 不把旧选区应用到新值 |

这些是独立测试进程中的实际 AppKit 控件与 SwiftUI host；活动窗口资格由测试子类控制，不能代替最终应用前台和完整双端验收。

## 正式包及待验收

`CARGO_NET_OFFLINE=true CARGO_TARGET_DIR="$PWD/.cache/subagent-controls-target" SHIPIOS_BUILD_CACHE_ROOT="$PWD/.cache/native-ui-654" script/build_and_run.sh --app` 构建运行命令 exit 0，Swift 构建 5.18 秒，日志 `.cache/search-return-formal-run-654.log`。严格深度签名检查通过，日志 `.cache/search-return-signature-654.log`。

正式 helper 的最终扩大关联为 **243 项、1 条失败、0 unexpected/跳过，61.024 秒，exit 1**，日志 `.cache/search-return-formal-associated-654.log`。新增 9 项全部通过；唯一失败仍为 `testPartialResultsKeepAWorkingSearchAlive`，查询约 0.425 秒后超时，收到响应为空，子进程 boot/query-read/全部 emitted 标记均缺失。该记录证明这一次超时发生在子夹具尚未完成启动标记前，不能据此确认底层启动停滞原因或把扩大组描述为通过。本轮没有 Rust 或通信实现变化，正式 helper SHA-256 仍为 `380bec2aac119df2c9755850f1aa6150dd14cb9403a2eb8d42eff39e7f54ae9b`；第 652 篇相同 helper 的 IPC/Core 冒烟证据保持，不将它描述成本阶段重新执行。

本轮两次请求正式应用前台，CUA 均返回 Mac 已锁定且自动解锁失败。**本轮没有确认最终包工作区可交互，也没有完成鼠标、Esc 和多窗口前台验收**；构建命令成功不能替代这些检查。

第 653 篇固定 `b4e81aa` 全量仍在原 handle `91319` 上运行；已有 58 个夹具、153 个资源、测试可执行文件和独立 helper 已核对未变。该套件不覆盖本阶段源码。文件搜索 400 毫秒间歇根因、全量终态、其余页面与核心矩阵缺口继续保留。
