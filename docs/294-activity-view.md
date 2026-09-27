# 主窗口 Activity 活动页

2026-09-27。Codex 桌面端[通知文档](https://learn.chatgpt.com/docs/notifications)说明，侧栏铃铛可打开 Activity 视图，集中查看未读、运行中和等待答复的任务，支持“全部标为已读”；[命令参考](https://learn.chatgpt.com/docs/reference/commands)给出 macOS `⌘⌥U` 切换快捷键。ShipiOS 此前已有任务未读、运行和待审批/提问/MCP 请求状态，但没有对应的集中页面。

现新增主窗口内活动页：侧栏铃铛、命令菜单和 `⌘⌥U` 可打开或关闭；页面按待处理、运行中、未读排序，可筛选，并显示所属项目。点击任务会切回其项目与会话，成功打开后沿用原有已读语义；跨项目打开失败会保留 Activity 页面和未读状态。全部标为已读只清除未读标记，仍待用户处理的请求继续显示。设置页面往返及 Esc 返回保持原页面状态；独立窗口的命令菜单可将入口交给主窗口。

19 项相关测试通过，覆盖排序、筛选、默认快捷键、设置往返、打开任务、全部已读及失败保护；`script/build_and_run.sh --build-app` 与 `codesign --verify --deep --strict` 通过。Mac 仍锁屏，页面视觉、侧栏铃铛与真实键盘/焦点行为尚未与 Codex 双端配对。当前只显示 ShipiOS 本地任务，不表示 Codex 的 Chat/Work、Pinned 或 Scheduled 等可用分类已全部对齐。
