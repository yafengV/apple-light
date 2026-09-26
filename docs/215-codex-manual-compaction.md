# Codex 会话手动整理上下文

2026-09-26。已有、空闲的 Codex Responses 项目任务现在可以在主窗口或独立任务窗口输入 `/compact`。命令通过私有 Agent RPC 提交固定版 Codex Core 的 `Op::Compact`，不把斜杠命令作为用户消息发给模型。任务时间线在收到 Core 的上下文压缩完成事件后显示“上下文已整理。”；如果没有完成事件，本轮标为失败。整理记录不再被 ShipiOS 的历史重组当作普通用户消息，后续回合继续使用 Core 保存的线程。

命令仅在已有成功的 Codex 会话、当前没有运行中的回合且没有草稿附件或待发送评论时可用。若私有线程记录已经丢失，不会创建一个空线程并误报整理成功。当前能力仅作用于已有项目中的 Codex Responses 任务。

验证：`cargo fmt --all --check`、`script/build_and_run.sh --build-app`、Rust Bridge 定向测试，以及 `ModelTransportTests/testCodexCompactCommandUsesCoreAndKeepsNextTurnContext` 和 13 项输入命令回归通过。集成测试由本地 HTTP 假服务驱动真实 Codex Core，覆盖主窗口斜杠命令、独立任务窗口命令、压缩后下一轮上下文和应用重启后恢复线程再压缩。Rust 测试还确认恢复专用启动在缺少线程记录时不生成新的线程引用。

这些是代码与自动化证据。主窗口和独立窗口的真实键盘、焦点、运行中提示、失败呈现及当前 Codex Mac 的视觉和行为配对仍待原生验收；43 类完整配对数量仍为 0。
