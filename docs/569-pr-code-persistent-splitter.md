# PR Code 文件树分隔栏

当前安装的 Codex PR Code 使用 `pull-request-code-review-78532b75d5ee.js` 中的分栏组件：默认左侧差异占 76%，窗口宽于 680px 时右侧文件树至少 220px、左侧差异至少 420px；较窄时文件树作为右侧抽屉。桌面分隔栏支持拖动、左右方向键与 Home／End，并把左侧比例保存到应用偏好，重开页面仍沿用。

ShipiOS 原来的右侧文件树从 260 点开始，限制在 220–360 点，页面重建后重置。现在按可用宽度和保存比例布局；宽窗口文件树可超过 360 点，拖动、方向键、Home／End 和辅助功能增减都更新同一个比例。680px 以下继续使用右侧抽屉。

`PullRequestCodeHeaderTests` 13 项通过，包含宽度约束、无效旧比例回退、宽窗口原生页面布局以及隔离偏好下的页面重建恢复；日志为 `.cache/pr-code-split-header-tests.log`。`script/build_and_run.sh --build-app` 正式构建及严格深度签名通过。Mac 锁屏使电脑控制无法读取前台窗口；真实拖动、焦点和 Codex 双端配对尚未验收，完整配对仍为 **0/47**。
