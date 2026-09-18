# 主窗口深链接导航

2026-09-17。补齐审计 I05 的产品 URL 路由。ShipiOS 注册独立的 `shipios` scheme，所有链接都进入已有主窗口导航，不创建设置窗口。

## 支持的链接

- `shipios://workspace`：返回当前任务工作区。
- `shipios://projects`、`shipios://plugins`、`shipios://automations`：打开相应主窗口页面。
- `shipios://settings` 或 `shipios://settings/<分类>`：打开主窗口设置及指定分类，例如 `appearance`、`connections`。
- `shipios://task/<任务或运行标识>`：在现有任务库中定位任务；跨项目时先切换项目作用域，再打开对应任务。

任务工具栏菜单增加“复制任务链接”。链接只包含 ShipiOS 内部任务标识，不包含提示、回复、项目路径或模型凭据。

应用恢复完成前收到的链接先进入内存队列，恢复完成后按顺序执行。未知 scheme、未知页面、带用户名/密码、超长任务标识、空任务标识和包含空白的标识会被拒绝。运行中的任务阻止切换时显示错误，不强制中断当前运行。

## 验证与边界

`DeepLinkTests` 覆盖所有页面和设置分类的解析/生成往返、恶意或无效 URL 拒绝、设置返回来源、任务/运行标识定位及缺失任务错误。打包脚本已注册 `CFBundleURLTypes`；实际生成的 `Info.plist` 通过 `plutil -lint`，并确认 scheme 为 `shipios`。

完整回归通过 325 项 Swift 测试、12 项 Rust 测试、Rust fmt/Clippy 和真实 Agent IPC 冒烟，日志记录在 `.cache/deep-links-full-tests.log`。

macOS 仍处于锁屏状态，无法用 LaunchServices + CUA 对可见页面跳转、窗口激活和焦点恢复做原生闭环。解锁后需要分别从应用关闭、恢复中和已运行三种状态打开页面与任务链接。

当前没有公共 HTTPS 分享链接、跨设备链接、插件详情/自动化详情链接或外部导入确认页。深链接只在当前 ShipiOS 独立数据根目录内解析，不读取个人 Codex 会话。
