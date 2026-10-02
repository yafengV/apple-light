# PR Code 跨内容标签恢复

当前安装的 Codex PR Code 资源 `pull-request-code-review-navigation-70694e0b833d.js` 将文件选择、搜索、文件树开关与纵向滚动位置按 PR 请求保存在页面组件之外。因此关闭 PR 内容标签再打开时，导航位置不会因为页面重新创建而丢失。

ShipiOS 原本只在 `TaskPullRequestDetailView` 的 `@State` 中保存这些值。现在 `WorkspaceStore` 持有最多 64 个 PR 的内存缓存：PR 页面离开视图树时保存搜索词、文件树开关、已选路径与滚动位置，再打开并加载同一版本代码后恢复。缓存按任务、仓库根目录、PR、head 及分支区分；不同任务或更新后的 head 不会借用旧状态。显式点击评论跳转优先于缓存恢复。应用重启不保留这一页面导航缓存。

`GitHubPRCodeTests` 31 项、`PullRequestContentTabTests` 10 项和 `PullRequestCodeHeaderTests` 11 项通过，覆盖跨状态实例恢复、任务隔离、筛选、评论跳转优先级及已有的原生页面操作。`script/build_and_run.sh --build-app` 正式构建与严格深度签名通过。前台电脑控制超时，页面焦点与滚动的双端配对仍未取得；完整验收仍为 **0/47**，这里的 47 项是待验收面，不是已确认差异数。
