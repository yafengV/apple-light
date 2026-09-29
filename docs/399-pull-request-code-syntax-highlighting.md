# PR Code 离线语法高亮

PR Code 已接入原生可选择的语法高亮文本。统一和并排视图使用各自旧、新侧的 token；浅色/深色切换直接选择预计算结果，保留文件折叠、评论、选区和行定位。该阶段只覆盖 PR Code，本地审查与文件预览高亮仍待接入。

## 当前参考及实现

只读核对 Codex 26.911.61220 / build 9647 的公开分发资源，没有访问个人认证、配置或聊天。参考可执行文件只保留在忽略缓存，不随项目发布。

| 参考资源 | SHA-256 | 行为 |
| --- | --- | --- |
| `worker-c95ad5902d1d.js` | `52842761c2b548b9840360e9bf1cddc23839303c59825eca3c87b7d270afae2b` | 默认 `shiki-js`；逐行 tokenization 上限 1000；部分差异每个 hunk 独立语法状态 |
| `shiki-highlight-provider-83fb33e3d6f0.js` | `b1fb3a9b6b04a0869c3b66a4b01ae3b6bd59e561e2c2b779f08fd0e7f1d3712b` | 按代码外观选择浅/深主题 |
| `codex-light-d03f2716c66a.js` | `bddacd4d49918c829b0d87e95ffb9f8e3ddea70d61bb191c525318f004b0f92c` | 浅色 TextMate scope、颜色、字体事实 |
| `codex-dark-c9c4e9fbc112.js` | `18e559d9fc983253fb28288296bda817ee198a7363606e948c00202039ec1c0f` | 深色 TextMate scope、颜色、字体事实 |

主题仅记录声明式外观数据，使用自有名称。引擎来自固定版本的 Shiki 4.4.3、@pierre/diffs 1.5.1；构建使用 esbuild 0.28.2，构建流程和依赖许可证见 `tools/syntax-highlighter/README.md`。发布包不需要 Node、npm、网站请求或用户已安装的 Codex。242 种规范语言表示目录可用，不表示所有语言都已完全对齐。

应用拥有独立、非持久、从未接入窗口的 WKWebView，只加载内置计算资源，禁止网站导航和网络连接。代码通过结构化参数传递，不进入 HTML；Swift 对源文本、行身份、颜色与字体位验证后才缓存和渲染。资源启动前验证大小及 SHA-256；损坏、超时、取消或进程退出保留普通文本，后续请求可重新启动。缓存最多 100 项且估算预算 16 MiB，按文件路径及内容版本区分。

旧、新两侧多行语法状态相互独立，部分差异的各 hunk 重新开始。Unicode、空行、制表符和 CR 内容保留原文；未知语言和超过参考逐行上限的代码保留可读文本。迟到结果、换文件、内容更新、折叠与窗口内独立状态受保护。渲染支持颜色、粗体、斜体和下划线，保留原行号、差异标记和原生文本选择。

## 验证

最终 Swift 相关回归 **85 项全部通过**，226.927 秒，见 `.cache/syntax-related-final.log`：语法 10、PR Code 18、生成文件 16、行内评论 23、文件标题/滚动 8、内容标签 10。实际隔离 WebKit 测试经自动审批允许运行，不显示窗口、不访问网站、不读取其他应用或个人浏览器资料；验证内置引擎、旧/新侧状态、代码作为文本、原生 token 颜色、资源损坏、失败恢复与迟到取消等边界。

Node **9 项全部通过**，见 `.cache/syntax-node-tests-final.log`。当前参考 worker 的 19 组自编样例、8 种语言、49 行代码，两种主题的全部 token 颜色及字体样式匹配；1,380 组默认扩展名与路径形式也匹配。参考与 upstream 的 8 个 grammar 注册中，Swift、Go、CSS 不完全相同；固定样例通过不能推广为全部语法完全一致。

正式应用通过 `script/build_and_run.sh --build-app` 构建、打包和签名（2.49 秒）；严格深度签名通过。包内 26 个资源文件与源资源逐字节一致，引擎 8,288,194 字节，SHA-256 为 `12600da3710db3bc5c8047f2d4252d4353dec96e04df75ed7599f83664656b12`，位于应用自己的 `Contents/Resources/ShipiOS_ShipiOS.bundle/SyntaxHighlighting`，不依赖开发构建目录。构建日志 `.cache/syntax-app-build-final.log`，资源/签名日志 `.cache/syntax-package-verification-final.log`。Rust 没有修改，不重复 Rust 全套测试。

## 验收边界

本轮没有启动正式应用或操作锁屏桌面。隔离计算和隐藏组件测试不等于可见工作区验收，更不等于当前 Codex 双端配对。完整配对仍为 **0/45**。

PR 的词级差异、媒体/二进制、完整文件菜单与编辑器入口、评论横向位置、代码主题选择，以及本地审查/文件预览高亮仍待补齐。审查者管理、联合 Fix、Watch/自动修复、持续同步、blame、跨聊天 PR 标签移交和其他主界面/设置页面仍属于完整目标。
