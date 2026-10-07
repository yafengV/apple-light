# 子任务附件历史与统一引用

接续[第 625 篇](625-browser-history-and-search-deadline-races.md)。日期：2026-10-07。范围是原生子会话提交的附件元数据、真实历史卡片、跨父子引用与删除保护；不是完整子任务或全部页面对齐完成。

## 已补齐的行为

| 内容 | 当前实现 | 验证边界 |
| --- | --- | --- |
| 提交前持久化 | 在 RPC 之前保存所属 task/root/child、原提示、图片/文件原始元数据及展开输入的 SHA-256/字节数 | 初次保存失败阻止请求；实际 Core 用例在提交期间清理父草稿，副本仍可读取 |
| 确认与不确定结果 | 回执保存实际 turnId；RPC 异常保留 unconfirmed，确认后的保存异常不将已发送消息报为失败 | 状态测试及实际 Core 注入确认保存失败；不把无回执当作从未发送 |
| 历史绑定 | 只匹配真实 native user item 的文字摘要、图片路径和回合身份；记录每次最多消费一次 | 错误文字/回合/路径不显示本地附件；无真实历史不生成气泡 |
| 历史卡片 | 展示原始提示、图片原名称与 Appshot 元数据、文本/PDF/文件夹文件卡片 | 复用现有图片/文件控件及其哈希读取校验，不把参考文本解析成可信文件路径 |
| 所属预览 | 子历史文件使用所属面板 sheet；图片使用既有图库 | 前台读取文件内容、图片名称、关闭及焦点恢复已操作 |
| 共享引用 | pending/accepted/unconfirmed 的图片和文件全部纳入 WorkspaceLibrary 统一引用表 | 父草稿移除不误删；删除一个共享任务不删除另一任务的资产；最后任务删除才回收 |
| 恢复 | 元数据保存在独立 workspace.json，旧记录无字段时迁移为空 | 实际关闭/recreate store、恢复原父 Core 线程、读取冷子历史后，原提示/图片/文件及副本保持 |
| 删除竞争 | 更新只能修改已存在的同身份 pending 记录；不能在任务删除后用迟到回执重建记录 | 状态/磁盘用例 |

展开的文件全文不再额外复制到元数据中；只保存匹配摘要。原生 Core 的实际历史仍是会话来源。旧子会话没有这些元数据时继续保留原参考文本和受限图片路径呈现，不能宣称能补回此前未保存的名称。

## 测试与正式包

初次新增测试编译发现调用了 private loadLibrary，未进入测试执行；原失败日志 `.cache/subagent-submission-unit-626.log` 保留。修正测试为正常 WorkspaceLibrary 磁盘加载，并另加实际应用状态恢复与父线程续接集成，没有放宽生产访问级别。

专项 13 项通过，0 失败/跳过，9.097 秒，terminal exit 0，`.cache/subagent-submission-focused-626.log`。其中 7 项元数据/引用/失败保护测试及 6 项真实 Core 附件集成。扩大关联 170 项通过，0 失败/跳过，49.026 秒，terminal exit 0，`.cache/subagent-submission-associated-626.log`。覆盖所有 Subagent、WorkspaceLibrary、主附件、任务删除/归档、侧聊及恢复相关组。正式包 Agent 同组专项 13 项通过，9.721 秒，terminal exit 0，`.cache/subagent-submission-bundle-626.log`；各组重叠，不累加。

补齐图片单独、文件单独及 PDF/文件夹的历史卡片断言后，最终正式包关联集 **170 项通过，0 失败/跳过**，53.824 秒，terminal exit 0，`.cache/subagent-submission-final-associated-626.log`。与此前集合重叠，不累加。Rust 沿用第 624 篇，未修改其源码，不重复计作新增 186 项验证。

`script/build_and_run.sh` 正式构建启动 exit 0，Swift 构建 5.42 秒；严格深度签名、包内 IPC 与 Core RPC 冒烟均 exit 0，分别 `.cache/subagent-submission-formal-run-626.log`、`.cache/subagent-submission-signature-626.log`、`.cache/subagent-submission-ipc-626.log`、`.cache/subagent-submission-core-rpc-626.log`。

## 实际前台验收

本轮前台可读取，不再沿用之前“Mac 仍锁定”作为当前状态。

1. 原工作区 `other` 可交互，无持续恢复 loading。⌘, 在同一 ID main 打开设置，浏览器的历史/下载/权限三个子页正确切换；Esc 返回 other 并恢复任务输入焦点。这是导航证据，不代表每页全部行为或 Codex 配对。
2. 首次将独立夹具置于桌面仓库的 .cache 中，应用持续恢复加载。实际 PID 18140 的采样显示 detached loadLibrary 停在 Foundation Data(contentsOf:) → open；主线程仍在正常事件循环。没有证据证明它是权限、文件系统还是其他原因，不记作启动成功。
3. 同样的夹具移到 `/private/tmp/shipios-ui-626`，再次通过正式脚本构建启动，exit 0，Swift 构建 0.15 秒；工作区完成恢复且可操作，日志 `.cache/subagent-submission-formal-run-tmp-626.log`。改变夹具位置使前台验证得以继续，不能称桌面读取停滞问题已经修复。
4. 前台发送 subagent-parent-complete 到仅监听本机的模型夹具；父回复为 Parent finished while child continues。从摘要进入子任务 Planck 详情，显示实际 Native child finished 历史。
5. 子附件按钮打开所属选择面板，从临时目录导入 child-reference.txt 和 child-picture.png；两类草稿卡片及各自移除入口可见。一次路径输入操作超时，重新绑定读取实际窗口并重新选择后成功；没有把超时当作应用退出。
6. 在子输入器输入 subagent-child-followup UI original prompt，⌘Enter 发送。草稿附件消失，历史显示原提示、原图片/文件名称和 Child followup only；父回复保持。
7. 点击历史文件卡片，所属 sheet 显示真实中英文内容；Esc 关闭后焦点回到子任务消息。点击历史图片打开图库，名称保持；Esc 后焦点回到原图片按钮。
8. 返回子列表再进入同一子详情，两类附件历史仍存在。
9. 测试完成后通过正式脚本恢复默认工作区，exit 0，Swift 构建 3.55 秒，`.cache/subagent-submission-default-run-626.log`。新包恢复 other 且可交互，再次实操同一 main 窗口设置/返回与输入焦点，没有持续 loading。

这些是当前 ShipiOS 正式包的真实前台证据。没有 Codex 同版本/同数据的完整双端操作证据，完整配对保持 **0/47**。

## 仍须完成

- 子输入草稿还未纳入完整跨窗口/冷恢复与统一引用生命周期；移除、清空、换子任务后的未发送副本回收仍需补齐。
- 无回执的记录保守持有引用直到任务删除；未实现基于完整原生历史的无歧义回收，不能因 RPC 报错直接删除可能已被接受的副本。
- 旧记录缺失元数据、远程/内联图片、更多二进制格式、全部子工具/权限/输入菜单、像素与完整焦点配对继续未完成。
- 桌面路径的读取停滞及启动错误恢复需要单独复现/处理；临时目录启动成功不替代这个问题。
- 第 625 篇全量 handle 99876 已缺失，原测试进程已确认不存在，日志没有最终结果；停止原因未知，保留 `.cache/full-alignment-regression-625.log`，不能记为通过或已知失败。第 621 篇仍是 2,668 项、2 跳过、2 失败的原终态。最新源码全量尚未取得终态。

全部 [29 项核心要求与 47 类页面](599-core-function-parity-matrix.md)范围保持，不用专项通过推算完成比例。
