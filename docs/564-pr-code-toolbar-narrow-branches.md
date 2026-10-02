# PR Code 工具栏窄窗口分支路径

当前安装版 Codex 的 PR Code 工具栏在宽度不足约 400px 时隐藏分支路径，较宽时分别截断 head 与 base 分支名，中间以方向图标表示合并关系。ShipiOS 原先始终显示单段 `head → base` 文本，窄窗口会占据差异选项、展开/收起、布局和文件树按钮的空间。现改为按工具栏实际宽度切换，并给完整分支关系保留无障碍标签。

同一参考页面显式关闭“隐藏空白差异”和“加载完整文件”两个通用审查选项；PR Code 不应添加这两个菜单项。现有刷新、自动换行、富文本预览及字词差异选项保持 PR 页面对应能力。

360px 工具栏、窄窗口换行/统一/并排页面及固定文件头共 **3 项离屏回归通过**，分别记录在 `.cache/pr-toolbar-branch-narrow.log` 和 `.cache/pr-toolbar-branch-targeted.log`。`script/build_and_run.sh --build-app` 构建成功，`codesign --verify --deep --strict` 通过。Mac 仍锁屏，Codex 与 ShipiOS 的实际尺寸、截断和键盘焦点配对尚未验收；完整双端配对仍为 **0/47**。
