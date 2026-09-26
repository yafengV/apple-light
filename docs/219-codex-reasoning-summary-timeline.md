# Codex 思考摘要时间线

2026-09-26。固定版 Codex Core 发出的 `reasoning_content_delta` 和 `agent_reasoning_section_break` 现在进入任务的有序时间线。同一 Core `item_id` 的片段合并到一张可展开的“思考摘要”卡，按 `summary_index` 保留分段；主窗口和独立任务窗口共用同一渲染视图。原始推理内容事件不进入界面或任务记录。

本地假模型通过真实 Codex Core 返回分段 reasoning summary 与最终回复。集成测试确认摘要卡先于回复、分段内容正确、重启后记录仍可解码；边界测试确认多段合并、原始推理排除及序列化。页面原生视觉、展开、焦点与键盘行为仍待和当前 Codex Mac 配对，完整配对数量不变。
