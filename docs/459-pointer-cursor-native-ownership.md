# 指针光标与原生控件光标

[Codex 外观设置](https://learn.chatgpt.com/docs/reference/settings)提供“使用指针光标”，用于可交互元素悬停时显示指针。ShipiOS 原有全局监听同时处理 `mouseMoved` 和 `cursorUpdate`，并对非按钮区域每次强制设置箭头。这会覆盖文本输入的 I 形光标、面板调整柄的双向光标、放大图片的拖拽光标，以及网页和终端自行管理的光标。

现在全局监听只响应 `mouseMoved`。启用偏好时，按钮和链接使用指针，普通区域使用箭头；文本视图与字段、面板调整柄、图片预览、WebKit 和终端返回给原生视图处理。禁用按钮仍用箭头。即使网页内部命中的视图标记为按钮，也先交给 WebKit，避免覆盖网页的 CSS 光标。

新增两项测试覆盖按钮、禁用按钮及其子视图、链接、普通区域和上述原生视图，相关外观、图片、面板、终端及浏览器 31 项测试通过。`script/build_and_run.sh --verify` 在系统权限下完成正式构建并启动进程；受限环境中的首次启动曾遇到 LaunchServices `kLSNoExecutableErr`。`codesign --verify --strict --deep` 通过。桌面控制接口超时，无法确认工作区交互，也未完成 Codex 与 ShipiOS 的可见指针行为配对；完整验收保持 **0/45**。
