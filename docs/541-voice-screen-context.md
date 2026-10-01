# 语音聊天按需读取屏幕上下文

Codex macOS 公开语音设置资源包含“屏幕上下文”开关：在语音聊天中提到屏幕内容时，可让客户端读取前台应用，首次需要时由 macOS 请求权限。ShipiOS 现增加同名开关，旧偏好默认关闭。

开启后的实时会话向独立 API 服务声明 `capture_screen_context` 客户端函数工具。模型请求该工具时，ShipiOS 复用现有 Appshot 目标与 ScreenCaptureKit 路径：先检查系统录屏权限，只采集可核对的前台／最近外部应用窗口且不弹出任意窗口选择器；将截图及限定长度的窗口标题、辅助功能文字作为不可信屏幕上下文加入当前语音会话，再回传工具结果并请求模型继续回复。关闭开关时不声明工具，服务即使返回同名调用也不会触发采集。权限缺失、无目标或采集失败均回传明确状态，并在语音浮层显示结果。

协议格式依据 [OpenAI Realtime function tools](https://developers.openai.com/api/docs/guides/realtime-mcp) 与 [Realtime 图片输入](https://developers.openai.com/api/docs/guides/realtime-conversations)。合成图片和函数调用事件、旧偏好迁移、设置搜索等 24 项语音相关测试通过，设置页离屏渲染、正式应用构建和严格签名通过。用户的独立实时服务凭据未配置，本机缺少麦克风，新包的桌面交互启动也仍失败，因此实际模型调用、权限弹窗、截图内容和 Codex 双端配对未验收；完整配对仍为 **0/47**（验收面数量，不是缺陷数量）。
