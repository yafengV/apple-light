# 托管工作树清理脚本

2026-09-26。本机 Codex `local-environment-editor` 的 Cleanup 描述为“Runs at the project root before worktree cleanup”，并提供默认/macOS/Linux/Windows 脚本。ShipiOS 环境页现可分别编辑这些脚本；自动归档或数量上限清理托管工作树前，优先运行 macOS 脚本，否则运行默认脚本。工作目录是来源项目，脚本可读取 `CODEX_SOURCE_TREE_PATH` 与 `CODEX_WORKTREE_PATH`。

清理前验证来源与目标仍属于原 Git 仓库。脚本失败时保留工作树，不创建归档快照；成功后先记录已执行状态，再捕获修改并按现有安全检查移除工作树。重试不会重复执行已成功的脚本。归档工作树恢复后清除此状态，下次清理会重新运行脚本。

真实 Git 工作树测试覆盖脚本失败、修正重试、macOS 覆盖默认脚本、执行目录与路径变量、清理成功及恢复后再次执行。归档恢复、数量上限及工作区存储等 13 项相关回归通过，`script/build_and_run.sh --build-app` 与严格签名校验通过。完整本地环境文件共享、环境目录选择和当前 Codex Mac 原生页面配对仍未完成；本轮 Mac 锁屏，无法验收实际窗口。
