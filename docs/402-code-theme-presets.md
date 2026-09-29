# 代码主题预设与独立浅／深选择

主窗口外观设置的浅色、深色区域现分别提供代码主题菜单，带颜色预览和当前选项；使用现有原生菜单控件，没有创建新设置窗口。28 个预设提供 16 个浅色、27 个深色选项，共 43 个变体。选择只修改对应侧的代码主题与预设明确指定的外观字段，不改变基础主题、另一侧外观、任务或草稿。

## 当前分发资源依据

参考版本为本机 Codex 26.911.61220 / build 9647。只读公开分发资源，不读取个人认证、配置或聊天，不通过桌面 UI 操作 Codex。

| 资源 | SHA-256 | 核对内容 |
| --- | --- | --- |
| `app-initial-b21bd554b363.js` | `01c04b2e5a96e5dd4c97e02ffa183f571a55bef7a221abd99404246c430f2212` | 28 个名称、变体资格、默认 Codex、颜色种子与部分字段合并 |
| `general-settings-ed7ca2006cd3.js` | `3a2ff568faaa71fa98cde8ca59a04d525baf13ce81a470ea8ae72c5283800753` | 浅／深区域标题中的代码主题菜单、选中状态、颜色预览和排序 |
| `worker-c95ad5902d1d.js` | `52842761c2b548b9840360e9bf1cddc23839303c59825eca3c87b7d270afae2b` | 实际主题语法 token 的颜色和字体样式 |

预设为 Absolutely、Ayu、Catppuccin、Codex、Dracula、Everforest、GitHub、Gruvbox、Linear、Lobster、Material、Matrix、Monokai、Night Owl、Nord、Notion、One、Oscurange、Proof、Raycast、Rose Pine、Sentry、Solarized、Temple、Tokyo Night、Vercel、VS Code Plus、Xcode。16 个浅色与 27 个深色选项按名称排序；不支持对应变体或旧配置缺少主题 ID 时回到 Codex。

21 个变体的 scope 配置与固定 `@shikijs/themes` 4.4.3 相同，直接使用该公开依赖。其余 22 个变体使用核对后的声明式颜色与 scope 数据，包括与此版本 upstream 有差异的 Catppuccin 两侧。没有打包 Codex 的可执行初始化器。目录、独立声明文件、注册映射和生成脚本位于 `tools/syntax-highlighter`，`build.mjs` 生成离线引擎、目录副本、组件清单及许可证。

## 状态、持久化与显示

- 参考预设是部分字段更新：没有指定的对比度、不透明偏好和字体继续保留；明确的 null 字体重置到默认。GitHub 保留用户字体与对比度；Linear 指定 Inter 和不透明；Xcode 只指定对应代码字体，保留此前界面字体；Notion 明确清空界面和代码字体。初次测试错误地把 Xcode 的默认种子误当作完整更新，核对实际 patch 后纠正测试前提。
- 外观先写入独立 `workspace.json`，成功后才发布状态和调用应用回调。失败保留原外观与草稿并显示错误，原生菜单也恢复原选择。导入主题沿用该保存路径。
- 高亮输入、任务加载身份与缓存包含浅／深主题组合。PR Code、本地审查、最近一轮和文件预览均使用该组合；切换不重新读取 Git/PR 或重置评论。相同源版本等待高亮时保留已有语法，取消和 generation 防止旧主题迟到覆盖。
- 代码前景／背景读取所选变体，增删和词级背景读取预设语义颜色。原生文件预览仅更新属性，保留源字符、选区、滚动位置与焦点。
- 预设字体支持逗号分隔的候选、引号字体名及 system-ui、ui-monospace 等通用回退。修复了应用构造前访问系统外观时直接解包 NSApp 的崩溃。
- 设置搜索新增浅色／深色代码主题两个目标，字段总数为 112。

## 验证

当前 worker 对 Swift、TypeScript、Markdown、Rust 的 172 个样例、516 行给出预期；43 个变体全部由实际隔离、非持久、无窗口 WebKit 与 Node 核对颜色、字体样式及源字节。双主题分词会按另一侧样式额外切分，因此比较时仅合并相邻且颜色及 fontStyle 全部相同的 token，不忽略任何颜色或源字符；不宣称 token 边界与单主题参考完全相同。

最终相关 **81 项 Swift 回归全部通过**（23.687 秒，`.cache/code-theme-swift-final.log`），包括 10 项主题测试、实际隐藏窗口的设置菜单选项／持久化／失败回滚，以及文件预览的选区／滚动／焦点保持和迟到主题保护。实际窗口始终不显示，不打开 popup 跟踪。**17 项 Node 全部通过**（1.790 秒，`.cache/code-theme-node-final.log`），包含既有语法与 2062 组词级样例回归。Rust 未修改。

正式包由 `script/build_and_run.sh --build-app` 构建（Swift 构建 2.60 秒），只构建，不启动；严格深度签名校验通过。29 个资源文件与源逐字节一致，目录副本包含全部 28 个预设／43 个变体，26 个组件许可证包括固定主题依赖与 JsDiff 的 BSD-3-Clause。引擎为 8,861,982 字节，SHA-256 为 `b143d98543375763b5d44af62599180fa9afc0f9c8be8d683ef39d42234aa3a7`。包内资源与签名核对结果记录在 `.cache/code-theme-package-resources-final.log`、`.cache/code-theme-package-signature-final.log`，构建日志为 `.cache/code-theme-app-build-final.log`。

## 尚未完成的配对

没有启动正式可见工作区，也没有取得两端可见页面或实际菜单跟踪的验收；隐藏控件和离线样例不能代替双端操作，完整配对保持 **0/45**。

参考界面的每个变体区域各有界面／内容／代码字体、导入／导出入口；当前 ShipiOS 仍保留活动侧字体设置和原有整套 JSON 分享。内容字体尚未进入完整渲染，分享格式、主题命令菜单、修改颜色后按钮色样、完整 chrome 颜色派生、菜单尺寸／滚动／焦点与像素布局仍需对齐。完整文件编辑、差异上下文、macOS 14 词级呈现、媒体、文件菜单、PR 监控及远程／云端／账户／插件页面仍在完整目标内。
