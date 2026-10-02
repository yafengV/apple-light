# PR Code 图片与 PDF 预览

依据当前 Codex Mac 的代码差异组件，常见图片始终显示预览，SVG 受富文本选项控制，PDF 始终显示预览。新增、修改与删除的文件分别使用 PR head/base 版本生成后图、前后图或前图；删除时保留右侧无内容占位。PDF 每侧独立按页显示，提供上一页、下一页及页数指示。面板布局和翻页控件的后续对齐见[第 563 篇](563-pr-binary-preview-panel-layout.md)。

ShipiOS 通过已有 GitHub CLI 身份读取 PR 仓库中的 Git Blob，读取前后校验 PR 身份、head/base 提交和仓库；每个对象验证大小、OID、Base64 内容和 Git Blob 哈希。二进制最大 10 MiB，超过上限或版本变化时回退到差异占位。通用命令仍默认限制 1 MiB，仅此预览请求提高到有界的 16 MiB 输出上限。图片经 AppKit 解码；PDF 使用单页静态渲染和翻页控件。

原实现曾尝试在隐藏窗口中使用连续 `PDFView`，离屏测试发现 PDFKit 图块释放会触发进程异常。现已改为接近 Codex 参考端的静态单页预览，离屏 SVG/PDF 渲染测试通过。PR 相关扩展回归 **89 项通过**，记录在 `.cache/pr-binary-regression.log`；`script/build_and_run.sh --build-app` 构建成功，`codesign --verify --deep --strict` 通过。当前 Mac 仍锁屏，不能验证工作区可交互或进行 Codex 与 ShipiOS 双端前台配对；完整逐页验收保持 **0/47**。
