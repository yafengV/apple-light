# PR Code 工具栏与 Markdown 富文本预览

进一步读取当前 Codex Mac 包内 PR Code 组件，确认专用工具栏依次是选项菜单、独立的展开／收起全部按钮、单击切换统一／并排差异按钮，以及文件树按钮；菜单提供刷新、自动换行、富文本预览和词级差异。ShipiOS 已据此纠正上一阶段的菜单布局。

Codex 的富文本选项默认开启：Markdown 文件在打开且未删除时按 PR head 版本渲染完整文件，而非仅渲染差异片段。ShipiOS 现从 GitHub 读取对应提交的 Markdown Blob，读取前后校验 PR 身份和 head/base 版本、仓库及字节完整性；切换任务或版本后丢弃迟到结果。预览不可用时保留代码差异，关闭富文本选项立即恢复代码差异。选项保存在 ShipiOS 自己的应用偏好中。

21 项 PR Code 与窄窗口回归通过，另有 1 项离屏 Markdown／代码差异切换渲染测试通过；`script/build_and_run.sh --build-app` 构建与严格签名检查通过。当前仅补齐 Markdown 正文。Codex 对图片、SVG 与 PDF 的预览、Markdown 中相对链接和图片、真实前台菜单焦点与视觉尺寸仍需继续对照，不能据此记为完整页面验收。通过前台控制接口复查，Mac 仍锁屏，双端逐页逐交互验收保持 **0/47**。
