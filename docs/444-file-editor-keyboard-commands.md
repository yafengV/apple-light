# 文件编辑器键盘命令

2026-10-01。参考客户端文件编辑器的当前键位包含 Tab/Shift-Tab、⌘[/⌘]、⌘/、Shift-Option-A、Option-上下、Shift-Option-上下及 ⌘Return。ShipiOS 现分别接入插入/移除缩进、按语言切换行/块注释、上下移动/复制所选行、在当前行下插入空行。Mac 端 Control-Option-P/N 也可移动行。Tab 根据两列缩进宽度补至下一缩进位；文本操作经原生 `NSTextView` 写入，进入同一草稿和撤销历史。修正了文本视图中 Escape 关闭文件查找时的按键识别。

文本变换按 UTF-16 位置处理选区，保留 CRLF 和无末尾换行的文件；移到最后一行时将新选区限制在实际文本内。Swift、Rust、JavaScript、Python、Shell、SQL 等使用对应行注释，CSS、HTML、Markdown 等使用块注释；选中块注释内部文字时再次切换会解除注释。75 项文件、查找、语法高亮、任务窗口及工作区相关回归通过，最终修正后另有 10 项定向复验通过，包含真实原生文本视图的注释、移动行、草稿与撤销，日志为 `.cache/file-editor-shortcuts-regressions.log` 和 `.cache/file-editor-shortcuts-final-targeted.log`。`script/build_and_run.sh --verify` 构建并启动正式应用，严格深度签名检查通过。

前台桌面仍锁定，无法确认实际按键、焦点和 Codex/ShipiOS 双端交互。选择区模型编辑、其他高级编辑命令与多面板仍待实现和配对。
