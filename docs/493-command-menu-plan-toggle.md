# 命令菜单的计划模式切换

当前 Codex macOS 客户端的命令文案目录包含 `composer.togglePlanMode`（“Toggle plan mode”）。ShipiOS 原先已有 `/plan` 和内部 `plan` 路由，但 `DesktopCommand.all` 没有该命令，因此命令菜单搜索不到它；内部路由也只会进入计划模式。

现在命令菜单的“会话”组提供“切换计划模式”。主工作区和独立任务窗口执行时，在标准与计划模式间切换，保留当前草稿并聚焦输入区；从目标模式进入时仍按原有流程暂停目标，然后进入计划模式。无任务可编辑时沿用现有命令可用性判断。

验证：`CommandMenuSearchTests` 11 项和命令弹层、独立任务窗口、输入区命令及快捷键 37 项回归通过；`script/build_and_run.sh --build-app` 构建通过，`codesign --verify --deep --strict` 通过，`git diff --check` 通过。尝试访问 ShipiOS 前台时 Mac 仍锁屏，无法检查真实命令菜单的视觉、焦点及双端操作。因此这只是已实现且经自动化验证的一项差异，完整配对仍为 **0/45**。
