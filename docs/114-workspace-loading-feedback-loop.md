# 启动恢复卡住：菜单栏绑定反馈循环

2026-09-18。用户报告应用一直显示“正在恢复工作区…”。这是真实启动阻塞，先前仅确认进程存在和单元测试通过不足以证明工作区可用。

## 根因与修复

对卡顿实例的三秒采样发现，主线程反复运行 `MenuBarExtraController.updateConfiguration → Binding setter → showInMenuBar → updateGeneralPreference → library setter → scene update`。系统回传与当前值相同的菜单栏插入状态，代码仍重新保存并发布整个工作区，触发下一轮相同回调。CPU 持续 100%，恢复任务无法继续，原生界面访问也超时。

`updateGeneralPreference` 现要求值可比较，在加载状态检查及磁盘写入前拒绝相同值。真实偏好变化仍保留原来的原子保存和错误处理。没有通过隐藏 loading、跳过恢复或清空数据掩盖问题。

## 验证

- 19 项通用设置与恢复回归通过：`.cache/workspace-loading-tests.log`。新增测试覆盖加载前系统回传，以及真实修改后的重复回传；核对无观察通知、无新文件/修改时间变化。
- 构建与严格深度签名验证通过：`.cache/workspace-loading-build.log`。
- 修复前采样：`.cache/shipios-loading-sample.txt`。
- 使用原 `.shipios-local/desktop` 启动，原生 UI 实际显示原任务及待发送草稿，没有恢复遮罩，按钮可用。⌘, 打开同一个 `ID: main` 设置页，点击“返回应用”成功回到原任务，草稿保留。
- 原生工具不再返回先前的 `AXError.cannotComplete`。不能继续把这些失败仅归因于外部工具或桌面状态。

## 后续差异

本轮还观察到设置页的辅助功能树包含隐藏页面，以及搜索框聚焦时一次 Escape 未退出设置。这些是后续需独立复核的交互问题；本次启动修复不代表全产品对齐完成。
