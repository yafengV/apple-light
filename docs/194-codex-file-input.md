# Codex Responses 文本与 PDF 附件

2026-09-26。Codex Responses 会话现在允许输入区已有的文本/代码/CSV/JSON 与可提取文字的 PDF 附件，也允许仅附件的新任务。Swift 继续复用 `FileAttachmentStorage` 对源文件的大小、哈希、格式、PDF 页数和提取文本做校验。提取内容超过 JSON-RPC 的 64 KiB 单帧容量时，Swift 把这一轮的文件上下文写入 ShipiOS 私有 `CodexStaging/<随机 UUID>.txt`，以只含 ID 和字节数的 RPC 请求通知 Agent。Agent 限定项目数据根目录、UUID、普通文件和 1 MB 大小，读入当前用户输入后立即删除临时记录；Swift 在请求结束或失败时再次清理。模型获得的是文件名与提取文字，不接收原 PDF 二进制。

本地假 Responses 服务的 Rust 测试确认约 80 KB 的附件文字实际出现在模型请求中、暂存文件已删除，且图片与原有文字回合继续成功。Swift 集成测试覆盖仅 80 KB 文本文件的新任务、同任务下一轮 PDF 提取文字、附件归属与暂存目录清理。Agent 全部 7 项测试、相关 Swift 51 项测试、`script/build_and_run.sh --build-app`、签名检查及打包 Agent stdio 冒烟通过。

这仍是只读 Codex 线程。工具审批、自主写入、运行中回合事件重放、真实用户服务兼容性，以及与 Codex 当前 Mac 客户端的逐页交互配对尚未完成。Mac 当前锁屏，新增的文件选择、预览、拖入、焦点和恢复行为尚未原生可见验收。
