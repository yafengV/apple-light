# 复制 Codex 会话记录路径

2026-09-28。Codex [命令参考](https://learn.chatgpt.com/docs/reference/commands)为 macOS 列出“复制会话路径”及默认快捷键 `⌘⌥⇧C`。ShipiOS 在主窗口和独立任务窗口的任务菜单及命令菜单接入同一命令。只有任务已建立真实 Codex Core 会话、其私有 `thread.json` 指向仍存在的记录文件，且线程 ID 与任务记录一致时，入口才可使用。复制的是 ShipiOS 独立数据目录中的实际会话记录路径。

路径解析会检查任务 ID、线程 ID、记录文件及符号链接后的归属，避免把不存在或越出该任务私有 Codex home 的路径放入剪贴板。单元测试覆盖有效路径、错误线程或任务、丢失文件与逃逸的符号链接；快捷键和窗口命令归属也加入回归检查。

14 项相关自动化测试、`script/build_and_run.sh --build-app` 及 `codesign --verify --deep --strict` 通过。Mac 锁屏期间无法验证实际菜单、剪贴板焦点及与当前 Codex Mac 的原生交互，完整配对验收仍未完成。
