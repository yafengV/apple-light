# 测试窗口生命周期与片段导航历史

日期：2026-10-07。接续[第 626 篇](626-subagent-attachment-history-and-references.md)。本阶段处理全量回归的真实失败及扩大复测发现的历史行为，不将测试修复当作全部 UI 完成。

## 原始失败与定位

第 626 篇固定 Agent／测试二进制的全量已取得终态：fmt、Clippy 和 186 项 Rust 通过；Swift exit 1，归档弹层有两处窗口集合断言失败，随后 signal 11 崩溃，没有完整 Swift 总数，后续 IPC 阶段未执行。原日志 `.cache/full-alignment-regression-626.log` 和状态 JSON 保留，不能继续写为“尚未取得结果”或全量通过。

实际 `xctest-2026-10-07-103251.ips` 指向主线程 `_NSWindowTransformAnimation dealloc` → `objc_release`，不是站点工具 Swift 调用栈。开启 Zombie 的浏览器单组复测以 exit 1／signal 5 收尾，捕获 `NSKVONotifying_NSWindow release: message sent to deallocated instance`，见 `.cache/window-lifetime-before-627.log`。测试手工创建的 NSWindow 没有关闭默认关闭释放行为。按 [Apple 的 ARC 要求](https://developer.apple.com/documentation/appkit/nswindow/isreleasedwhenclosed)，将该 fixture 的 isReleasedWhenClosed 设为 false；不改生产浏览器行为来掩盖测试过度释放。

归档断言中实际集合比原集合少了两个窗口，没有新增窗口。测试原来要求整个进程所有窗口永久存在，误将其他 fixture 的异步关闭记成弹层失败。现仍禁止任何新窗口，断言当前集合是原集合子集，增加无关窗口关闭场景，并核验原 NSWindow 的 contentView 与 host.window 身份、无 sheet 及正常／紧凑宽度实际渲染。

## 片段跳转历史

初次修正窗口后 76 项归档／浏览器通过。扩大外观组合 183 项中出现 1 项失败：独立任务窗口的同文档 `#section` 跳转进入历史；该轮不记为通过。日志 `.cache/window-lifetime-associated-627.log`。

BrowserTab 原来按完整 URL 判定新访问，片段变化被误认成新文档。现按已有 sameDocument 语义比较，保留原访问 URL 作为标题更新的键，不新增记录、改变顺序／时间或复活已清理记录。正常跨文档导航与真正刷新仍记录新访问，首次带片段的地址也保留原地址。

新增真实 WebKit 用例覆盖：首次带片段页面 → 导航到另一片段 → 更新标题 → 保留原 ID、时间与 URL → 清理 → 页面脚本改变片段和标题 → 内存／磁盘仍为空 → 实际 reload 生成新的当前地址记录。独立任务窗口页面与主任务选择／草稿保持的原测试继续保留。

## 验证

最终归档／浏览器／外观组合 **184 项通过，0 失败／跳过**，69.475 秒，terminal exit 0，`.cache/window-history-fixed-627.log`；与先前 76 项重叠，不累加。此前失败及 Zombie 诊断全部保留。

两项片段／任务窗口专项再次通过（0.783 秒），`.cache/fragment-history-repeat-627.log`，与 184 项重叠。

通过 `script/build_and_run.sh` 构建并启动正式包（Swift 76.16 秒，exit 0）；严格深度签名、包内 IPC 与 Core RPC 冒烟均 exit 0，分别 `.cache/window-history-formal-run-627.log`、`.cache/window-history-signature-627.log`、`.cache/window-history-ipc-627.log`、`.cache/window-history-core-rpc-627.log`。Rust 未修改，186 项沿用本次第 626 篇全量已取得的 Rust 终态，不重复计作新测试。

实际前台隔离根 `/private/tmp/shipios-ui-627` 完成恢复，工作区可交互。从 ⌘K 筛选“浏览器”并新建标签，地址栏打开本机夹具 `/one#initial`，⌘L 改为 `/one#next` 后仍为同一标签。⌘, 在同一 ID main 打开设置，浏览器历史仅显示原 `/one#initial` 一条；Esc 返回原浏览器，点击后退按钮回到 initial。Esc 后紧接 ⌘← 的批量操作没有观察到后退，不计快捷键验收通过；按钮后退有实际状态证据。测试服务器已停止，随后用正式脚本恢复默认工作区（exit 0，`.cache/window-history-default-run-627.log`），实际 other 可交互，⌘K 打开菜单，Esc 返回 other 并恢复任务输入焦点，无持续恢复 loading。

当前源码全量仍须取得新终态；184 项专项通过不改变第 626 篇原全量失败。完整双端配对仍 **0/47**；[29 项核心与 47 类页面](599-core-function-parity-matrix.md)范围不变。子会话未发送草稿恢复／回收、桌面路径读取停滞、所有页面和焦点交互继续未完成。
