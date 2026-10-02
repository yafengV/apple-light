# PR Markdown 相对资源

Codex 当前差异预览的 Markdown 组件会以正在预览的文件路径解析相对媒体，并按需读取文件。ShipiOS 的 PR 预览现在将 `../`、`./`、百分号编码路径及表格中的图片引用解析到当前 PR head 文件树；图片通过 GitHub CLI 读取对应 Git Blob，验证仓库、提交、大小、OID、内容哈希以及读取前后的 PR 身份。图片缺失或校验失败时显示替代文字，不把失败内容当成有效图片。

相对 Markdown 链接固定到当前 head 提交的 GitHub `blob` 地址并保留锚点；越出仓库根目录的路径不生成链接。绝对网页链接和已有 GitHub 评论附件保留原有行为。图片只在展示时按需读取，切换任务或 PR 版本后丢弃迟到结果。

本阶段 44 项 Markdown、PR Code 和评论媒体相关回归通过，包括路径解析、表格、真实 Git Blob 夹具、错误/版本变化及隐藏页发起读取，记录在 `.cache/pr-markdown-relative-regression.log`。`script/build_and_run.sh --build-app` 构建成功，`codesign --verify --deep --strict` 通过。隐藏 macOS 窗口未能可靠绘出异步 Markdown 内容，因此不能把该检查算作图片的实际可见验收；当前 Mac 仍锁屏，也不能确认工作区可交互。Codex 与 ShipiOS 的完整双端配对仍为 **0/47**。
