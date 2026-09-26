# Codex Core 本地模型回合验证

2026-09-26。在固定版本的独立 host 中启动本机临时 Responses API 服务，向 `ThreadManager` 提交一个文字回合。服务只返回固定 SSE 事件，不需要用户 API Key，也不调用外部模型。

验证确认：Codex Core 对本地 `/v1/responses` 发出且仅发出一次 POST，正文包含用户输入；线程先给出完整 `AgentMessage`，后给出 `TurnComplete`，其最终回复与服务固定文本一致。随后加入进程内 ephemeral auth 测试：请求携带假 Bearer 密钥，`auth.json` 和 rollout 均不含该密钥，测试结束后内存认证条目被清除。回合结束后 rollout 文件出现在 ShipiOS 临时 home 中，另一临时 Codex home 未新增文件。关闭测试 provider 继承的 WebSocket 支持标记后，原先的多次 GET 探测消失；独立 API 服务的能力标记必须按实际协议设置。

通过 `./script/check_codex_core_embed.sh` 重跑。第一次构建需获取 Rust 测试依赖，运行时需要允许绑定本机 loopback 端口。测试使用的假服务和假回复仅用于验证线程事件、请求归属及隔离路径。

产品 `shipios-agent` 和 Swift UI 仍未接入 Codex Core。本轮没有验证增量文字 delta、停止/取消、工具调用与审批、结构化提问、异常恢复或用户实际填写的独立 API 服务；所选服务还需确认支持 Codex Core 所需的 Responses 协议。界面与 Codex Mac App 的逐页配对仍未完成。
