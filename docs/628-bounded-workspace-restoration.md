# 工作区读取超时与恢复入口

日期：2026-10-07。接续[第 627 篇](627-window-lifetime-and-fragment-history.md)。针对第 626 篇实际前台采样中 loadLibrary 阻塞在 Foundation open，导致整个主窗口持续禁用的问题。本阶段为读取等待和恢复错误提供确定的 UI 收尾，不宣称已修复造成系统文件读取阻塞的根因。

## 行为

- 独立数据根的 WorkspaceLibraryReader 在主 actor 外读取工作区，界面每次最多等待 15 秒；读取错误或超时均区别于空工作区，不把默认空数据写回磁盘。
- 未完成的同步读取只保留一个；超时后重试共享当前读取，不累积阻塞线程。调用者各有期限和取消身份，取消一个等待者不取消其他等待者。
- 超时或取消的迟到结果没有恢复权限。旧读取最终结束后，下一次重试重新读当前磁盘文件，不缓存旧结果。
- 超时后 busy、libraryLoading、restoringLibrary 收尾；同一主窗口显示“无法恢复工作区”和“重试恢复”，重试按钮支持默认 Return 操作并请求键盘焦点；实际 Return 已验证，原生按钮焦点外观仍待配对。背景页面、命令、快捷键和模型任务启动保持禁用，避免用户在未读完记录时操作临时空状态。
- 成功重试恢复真实记录与草稿，清除读取错误，并重新允许正常导航。现有损坏 JSON 修复与独立数据根测试继续保留。

同步文件系统调用本身无法由 Swift Task.cancel 强制终止。如果底层 I/O 永不返回，重试仍会超时；本阶段没有提供系统调用强制终止或修复桌面文件系统／权限根因。模型配置、插件等其他恢复步骤也不因这一项读取期限而被宣称全部有界。

## 验证

原有恢复组 4 项通过，`.cache/workspace-read-initial-628.log`。新增实际阻塞读夹具与原恢复共 **7 项通过，0 失败／跳过**，0.364 秒，terminal exit 0，`.cache/workspace-read-focused-628.log`。包含超时／重复重试不新增 I/O／磁盘不重写／迟到结果不恢复／修复后新读取、两个等待者取消隔离及实际 store 取消收尾。

扩大命令菜单、归档与设置／键盘关联共 **38 项通过，0 失败／跳过**，1.923 秒，terminal exit 0，`.cache/workspace-read-associated-628.log`。与 7 项重叠，不累加。使用不同于第 627 篇全量的默认缓存；没有修改正在运行全量的测试二进制或固定 Agent。

`script/build_and_run.sh` 正式构建／启动 exit 0（Swift 2.78 秒，`.cache/workspace-read-formal-run-628.log`）；严格深度签名、包内 IPC 和 Core RPC 冒烟均 exit 0，分别 `.cache/workspace-read-signature-628.log`、`.cache/workspace-read-ipc-628.log`、`.cache/workspace-read-core-rpc-628.log`。Rust 源码未改，不重复计数。

## 原生前台

1. 隔离根 `/private/tmp/shipios-blocked-ui-628` 的 FIFO 文件被 Foundation 立即拒绝为读取权限错误，没有复现阻塞，因此不把它记成 15 秒超时证据。实际 main 窗口显示恢复错误、可点击重试按钮，背景与工具栏禁用。
2. 将这个自有测试文件修复为含 Recovered UI draft 628 的普通 JSON，点击“重试恢复”，在原 ID main 恢复工作区与该草稿，控件重新启用，没有另开窗口。
3. 通过正式脚本重新启动第 626 篇实际阻塞过的桌面测试根 `.cache/subagent-ui-626/Data`（`.cache/workspace-read-desktop-run-628.log`，exit 0）。初始原生树确实为“正在恢复工作区…”，随后转为“读取工作区记录超时”和可用的重试按钮。
4. 按 Return 实际重新出现恢复 loading，随后再次按期限转为超时／重试，原窗口和禁用背景保持。此项证实实际底层停滞有 UI 收尾；没有把脚本启动成功当作工作区成功恢复。
5. 通过正式脚本恢复默认数据根，结果见 `.cache/workspace-read-default-run-628.log`；新包实际恢复 other 且可交互，⌘, 在原 ID main 打开设置，Esc 返回 other 并恢复任务输入焦点，无持续 loading。

第 627 篇固定提交 31d2b43 的全量仍由原 handle 72759 运行，使用独立冻结缓存，不覆盖本阶段新增读取代码。已观察到 AppearanceThemeImportTests 中一项真实通知点击用例有两处断言失败，尚无全量终态；不能记为通过。该失败及底层桌面读取根因继续待定位。当前[47 类页面／29 项核心](599-core-function-parity-matrix.md)范围保持，完整双端配对 **0/47**。子草稿恢复／统一引用等其余功能缺口继续保留。
