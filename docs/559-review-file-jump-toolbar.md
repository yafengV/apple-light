# 本地审查文件跳转与 PR Code 工具栏

复核 Codex Mac 的两种审查工具栏后，将“跳转到文件”弹层从 PR Code 专用页移到本地代码审查页。弹层保留文件名优先的模糊搜索、方向键／回车选择与空状态；选择后按当前审查范围定位差异，展开已折叠文件。最近一轮审查使用记录中的文件 ID 定位，因此即使原工作区路径不可用，仍可跳转差异。

PR Code 工具栏当时改为选项菜单、差异布局菜单和文件树开关。继续核对参考源码后，确认差异布局实际是单击切换按钮，展开／收起全部也有独立按钮，富文本预览属于选项菜单；本段初次判断已由[第 560 篇](560-pr-rich-markdown-preview.md)修正。

`ReviewFileJumpTests` 与 `GitHubPRCodeTests` 共 22 项通过，`script/build_and_run.sh --build-app` 构建通过。扩展到 `PullRequestCodeHeaderTests` 时，9 项中 8 项通过；剩余剪贴板测试的 `NSPasteboard.withUniqueName().setString` 在当前锁屏测试进程中返回 `false`，单独重跑仍失败，该测试与本次代码无关。锁屏状态下未能进行两端前台焦点、菜单、滚动及视觉验收，因此 47 项页面／交互配对验收仍为 **0/47**。
