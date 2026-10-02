# PR Code 布局与换行共享偏好

当前安装的 Codex 资源 `pull-request-code-review-78532b75d5ee.js` 在 PR Code 工具栏读取通用差异布局与换行偏好；对应偏好由 `app-initial-b21bd554b363.js` 的 `editorDiffViewMode` 与 `wrapCodeDiff.2` 持久保存。它们不是按单个 PR 创建的页面临时状态。

ShipiOS 原本将并排／统一布局和自动换行保存在每个 `GitHubPRCodeState` 中，切换 PR 或重开标签会恢复默认。现在两项偏好保存在 ShipiOS 独立的 `WorkspaceLibrary`，PR Code 页面在进入时读取，任一 PR 页面修改后同步到同一工作区的其他 PR 页面，应用重启也会恢复。写入失败不发布新值，原有草稿和标签数据不受覆盖。

`PullRequestCodeHeaderTests` 14 项和 `CodeWordDiffTests` 10 项通过，覆盖两个原生 PR 页面同步、工作区持久恢复及已有词级差异行为。词级差异套件最初在沙箱中因 WebKit 高亮子进程退出而失败，允许子进程运行后同一套测试通过。`script/build_and_run.sh --build-app` 正式构建及严格深度签名通过。通用 Git 审查页随后在[第 571 篇](571-git-review-shared-diff-display.md)接入相同偏好；Mac 锁屏使真实前台工具栏、焦点和 Codex 双端配对仍待验收，完整配对保持 **0/47**。
