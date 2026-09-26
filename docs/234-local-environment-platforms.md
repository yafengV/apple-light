# 本地环境平台脚本与变量

2026-09-26。本机 `/Applications/ChatGPT.app/Contents/Resources/app.asar` 的 `local-environment-editor` 与本地环境数据 schema 显示：setup 分默认、macOS (`darwin`)、Linux、Windows 脚本，Action 图标为 tool/run/debug/test，并可限制为单个平台；初始化脚本可使用 `CODEX_SOURCE_TREE_PATH` 和 `CODEX_WORKTREE_PATH`。

ShipiOS 环境页现在可分别编辑四种 setup 脚本、查看变量说明，并为 Action 选择图标和平台。新托管工作树优先运行 macOS 脚本，未配置时运行默认脚本，同时传入真实来源目录与工作树目录。顶部菜单只列出全部平台及 macOS 的有效 Action。旧版工作区配置缺少这些字段时仍可读取，上一阶段保存的 SF 图标名称会迁移到对应的 Codex 图标类别。

真实工作树测试覆盖默认脚本失败、macOS 覆盖脚本成功、环境变量值和成功后的重试；真实终端及存储测试覆盖平台过滤和持久化。Codex 的 cleanup、共享 `.codex/environment.toml` 及环境目录选择仍未接入；原生页面对照仍待 Mac 解锁。
