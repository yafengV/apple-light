# 通用 Git 审查差异布局与换行

Codex 的本地审查与 PR Code 使用同一组 `editorDiffViewMode`、`wrapCodeDiff.2` 全局差异偏好。ShipiOS 在第 570 篇先让 PR Code 保存和读取这两项偏好，但普通 Git 文件审查与“最近一轮”仍只显示不换行的统一差异。

现在通用 Git 审查工具栏提供独立的统一／并排切换，差异选项中提供自动换行；普通文件审查、嵌套仓库和“最近一轮”使用同一工作区偏好。并排视图复用已有的删除／新增行配对规则；hunk 暂存控件与补丁元数据保留整行，左右侧分别显示旧／新行号。评论在配对行后只显示一次，左右侧原有的打开文件和行内评论入口仍按原行锚点操作。开启换行后文本在可用列宽内排版，关闭后保留横向滚动。

原生离屏测试覆盖普通文件审查和“最近一轮”的横向滚动／换行切换，以及长差异行在窄列内增高。相关回归通过：`LastTurnReviewTests` 16 项、`GitReviewTests` 和匹配到的 `NestedGitReviewTests` 共 27 项、`GitHunkTests` 9 项、`ReviewCommentsTests` 6 项，另有一项定向行布局测试。`script/build_and_run.sh --build-app` 正式构建及严格深度签名通过。Mac 仍锁屏，前台鼠标、键盘、真实评论发送及与 Codex 双端布局仍须验收，完整配对保持 **0/47**。
