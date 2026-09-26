# Codex Core 结构化提问与回答

2026-09-26。固定版 Codex Core 的 `request_user_input` 现在会在 ShipiOS 任务时间线中生成提问卡片。选项、自由填写及密文填写均使用同一回合；回答通过私有 `codex.turn.answer` RPC 返回 Core，随后会话继续。侧栏与需关注任务导航会标记等待回答的任务。

固定 Core 的普通模式必须显式启用 `DefaultModeRequestUserInput`，且每个问题至少提供一个选项。本次使用固定版 Core 的功能开关，没有修改用户个人 Codex 配置。卡片保存问题、选项和回答状态；ShipiOS 工作区记录不保存回答值。密文填写使用 `SecureField`。任务结束、取消或应用重启后，等待中的卡片会退出可回答状态。

本地假模型的 Agent RPC 冒烟已验证提问、回答与完成；Swift 集成测试验证时间线、回答后继续会话及工作区 JSON 不含测试回答，单元测试覆盖问题校验和非阻塞提问到期；42 项模型传输回归、Rust 测试、`script/build_and_run.sh --build-app` 与应用签名验证均通过。当前 Codex Mac 的原生卡片布局、焦点顺序、键盘和密文呈现仍待桌面解锁后逐项配对；真实用户 API 服务需在用户填写后验证。
