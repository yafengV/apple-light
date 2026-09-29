# 词级差异高亮与共享开关

PR Code、本地 Git 审查和最近一轮差异接入同一词级差异偏好。默认关闭，使用各审查页的“差异选项”菜单开启/关闭；主、独立任务及分离审查窗口读取同一个 WorkspaceStore。保存失败保留原值与草稿，显示错误，不假装成功。

## 当前分发版参考

本机当前 Codex 为 26.911.61220 / build 9647。本轮只读公开分发资源与 SDK，没有读取个人认证、配置、聊天或其他应用页面。

| 资源 | SHA-256 | 核对事实 |
| --- | --- | --- |
| `worker-c95ad5902d1d.js` | `52842761c2b548b9840360e9bf1cddc23839303c59825eca3c87b7d270afae2b` | `word-alt` 范围计算、UTF-16 偏移、默认 1000 逐行上限、逐变化块同序号行配对 |
| `code-diff-6f2c1505ae04.js` | `f2b9a02a3f323fa7d53b9db7566dadb8c4d8eed41c2ba2cf7ddf0f5db6fb3b7e` | 读取共享开关，单文件增删总数超过 2000 时使用 none |
| `pull-request-code-review-78532b75d5ee.js` | `5a4ef4f4476dd6b86362cb98c2db0247e7185fef4bda9339af44bbe83afaef0e` | PR 与本地审查共享偏好，以及 Enable/Disable word diffs 菜单 |

公开主资源中的 `wordDiffsEnabled.2` 默认 false；CSS 的背景圆角为 3px、浅色透明度 .15、深色 .2，默认增删颜色来自同资源。项目使用 BSD-3-Clause JsDiff 9.0.0 比较词语，独立实现已核对的 word-alt 合并规则；没有复制 Codex 可执行代码。直接依赖固定版本、生成包清单和许可证随应用一起打包。

自编样例与固定种子随机样例共 **2062 组**，涵盖标点、内部单字符中性片段、终尾中性片段、空白、中文、emoji/肤色、组合字符、CRLF 和长行。预期范围由当前 worker 计算，仅声明数据进入测试 fixture。Node 初轮全 15 项通过，2062 组范围无差异。这不表示全部语法、页面或所有可能输入已相同。

## 行身份、计算与原生呈现

- 同变化块的旧/新行按序号配对；上下文与 hunk 边界结束配对，多出的一侧没有词级背景。新建/删除整份文件没有对侧，不产生范围。
- 1000 上限按 UTF-16 单元计算；超过 2000 增删行的单文件关闭词级比较。只移除实际终尾 LF/CRLF，保留无结尾换行时的单独 CR；patch 中的 No newline 标记随输入传入。
- 开关关闭时不计算词级范围。语法缓存的身份包含开关，切换不会错误复用另一种结果；等待新结果时保留同一源版本的语法 token，并立即清理旧范围。取消和迟到结果继续通过 generation 检查。
- 原生 Text 保留原源字符、语法颜色和字体样式；词级范围可以横跨多个 grammar token。TextRenderer 在实际 glyph run 后绘制背景，同范围的相邻 run 合并为一块，每个折行单独绘制圆角。没有把代码换成 HTML 或逐词 HStack。
- +/− 标记独立于源码偏移；行号、评论控件、统一/并排、自动换行与既有打开文件入口保持原组件。开关变化不重新读取 Git/PR 或重置评论草稿。
- 原生公开 `.textRenderer` 需要 macOS 15+。当前机器 macOS 26.6.2 已进入实际离屏绘制验证；macOS 14 保留语法文本并禁用词级菜单，完整 macOS 14 词级呈现仍是兼容差距，不提高项目最低系统版本，也不用私有 API 绕过。

## 验证与剩余边界

首轮原生定向 8 项通过，包括实际非持久、无窗口 WebKit 对全部 2062 组结果的核对，以及 ImageRenderer 的背景、换行和语法颜色像素检查。绑定按需计算、缓存身份和迟到结果保护后，相关 82 项 Swift 回归全部通过（77.686 秒，`.cache/word-diff-related-final.log`），含 10 项新增词级测试；补充 PR Code/范围评论 41 项全部通过（164.877 秒，`.cache/word-diff-pr-regression-final.log`），两组去重共 **123 项**。补充回归日志一度停顿，进程采样确认仍在执行项目自己的命令 fixture，保持同一 handle 等待后正常完成，没有重启。最终 Node **15 项全部通过**（1.411 秒，`.cache/word-diff-node-final.log`）。正式应用经 `script/build_and_run.sh --build-app` 构建、打包与签名通过（2.50 秒，`.cache/word-diff-app-build-final.log`），严格深度签名校验通过。27 个资源文件与源逐字节一致，引擎为 8,296,131 字节，SHA-256 为 `454957489c60edf4635a76df8da0064eee79de43b4a8fac87b0c5463ff0122b0`；25 个组件的许可证清单包含 JsDiff 的 BSD-3-Clause。包核对初次脚本误将 JsDiff 许可证假定为 MIT，读取实际包和许可证后已纠正，资源本身未损坏。日志为 `.cache/word-diff-package-resources-final.log` 和 `.cache/word-diff-package-signature-final.log`。Rust 没有修改，不重复全套 Rust 测试。

本轮没有启动正式可见工作区，没有取得 Codex/ShipiOS 双端可见页面验收。离屏绘制不能代替实际鼠标选择/复制、菜单与焦点、全部窗口以及主题布局的配对；完整配对保持 0/45。

完整文件编辑、差异完整上下文、代码主题选择、媒体、文件标题完整菜单、PR 监控与联合修复，以及远程/云端/账户/插件等页面仍在完整目标中。
