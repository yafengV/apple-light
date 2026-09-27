# 首个环境操作快捷键

2026-09-27。官方 [macOS 命令说明](https://learn.chatgpt.com/docs/reference/commands#keyboard-shortcuts) 将 ⌘⇧D 绑定到“运行环境操作 1”，并限定为环境定义了主操作时可用。ShipiOS 此前把这个组合固定给“构建 iOS 项目”，与环境操作的配置及执行语义不符。

现在 ⌘⇧D 执行当前窗口所属项目中第一个可在 Mac 运行的环境操作；若项目未定义此类操作，命令禁用。主窗口与独立任务窗口各自在所属项目的新终端标签运行脚本，Linux 专属操作不会占据第一个可运行操作的位置。固定“构建 iOS 项目”仍保留菜单入口，但不再使用这个默认快捷键。用户自行修改的快捷键继续由现有偏好设置处理。

`TerminalSessionTests` 与 `TaskWindowCommandTests` 共 20 项相关测试通过，其中真实终端测试验证了脚本执行顺序、非 Mac 操作过滤及离开工作区后命令禁用。`script/build_and_run.sh --build-app` 构建通过，`codesign --verify --deep --strict` 通过。当前 Mac 界面控制超时，菜单实际启用状态、按键投递及与用户安装的 Codex 窗口配对仍未完成，因此不计入完整 UI 验收。
