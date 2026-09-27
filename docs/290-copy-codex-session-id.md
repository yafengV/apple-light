# 复制 Codex 会话 ID

2026-09-27。Codex 官方[命令参考](https://learn.chatgpt.com/docs/reference/commands)列出 macOS 的“复制会话 ID”快捷键 ⌘⌥C。ShipiOS 的 Codex Core RPC 已返回真实线程 ID，但此前客户端没有保存或呈现此标识。

现在启动或恢复 Responses 线程后，将 RPC 返回的 `threadId` 记录到所属任务并保存。主窗口和独立任务窗口可通过任务菜单、命令菜单或 ⌘⌥C 复制该 ID；没有真实线程 ID 的任务不启用命令，避免把 ShipiOS 任务 ID 误称为 Codex 会话 ID。线程重新建立时更新记录，既有任务记录的解码保持兼容。

28 项相关测试通过，包含 ID 格式、任务归属、持久化、主窗口与独立任务窗口命令绑定；`script/build_and_run.sh --build-app` 构建与 `codesign --verify --deep --strict` 通过。当前 Mac 锁屏，真实剪贴板与 Codex 双端原生操作未验收；完整配对验收面仍为 0/43。
