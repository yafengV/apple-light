# 字体平滑偏好与文字渲染入口

本阶段接入外观高级区的字体平滑、独立保存、旧数据迁移、搜索和高级重置，并把渲染偏好传入应用自己持有的原生文字视图及离线代码预览。SwiftUI 系统文字与其余文字控件没有全部覆盖，外观整页和全应用完整对齐仍未完成。

## 公开参考的实际语义

核对安装包的公开资源，版本 `26.930.51102`、构建 `13100`。`lc` 只在 macOS 显示开关，默认开启。当前中文说明是“使用 macOS 原生字体抗锯齿”。`GTs` 的布局 effect 在 macOS 开启时向 HTML 根节点和 body 写入 `-webkit-font-smoothing: antialiased`；关闭时移除该行内覆盖，不能解释为关闭抗锯齿。

公开基础样式已经为 `html,:host` 设置 `antialiased`。因此移除行内值后仍可能得到相同计算样式；不能为了制造肉眼差异而把关闭实现为 `none`。本阶段的实际 WebKit 测试确认了应用离线文档的这一情况。

`script/extract_font_smoothing_reference.cjs` 校验设置、主程序、共享配置和基础 CSS 四个公开资源的 SHA-256，再隔离执行真实组件与 effect 函数。夹具保存 6 组平台/选中状态的可见性和真实回调，以及 8 组平台/偏好/渲染就绪状态的根节点、body 输出。React、存储、主题和 DOM 写入接口使用最小桩，不启动参考应用，不读取个人配置或会话。

原生绘制采用与 WebKit `Antialiased` 模式相符的 Core Graphics 策略：启用抗锯齿并关闭额外字体平滑，在绘制结束后恢复原图形状态。关闭偏好时不覆盖默认上下文。对应语义见 [WebKit 的 Core Text 字形绘制实现](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/platform/graphics/coretext/FontCascadeCoreText.cpp)与 [Apple 的字体平滑 API](https://developer.apple.com/documentation/coregraphics/cgcontext/setshouldsmoothfonts(_:))。这不保证两个渲染器的字体度量或所有像素一致。

## 实现范围

`AppearancePreferences.useFontSmoothing` 默认 `true`，旧工作区缺少字段时按默认迁移；完整主题导入/导出保留该独立值。高级重置恢复开启，同时保留视觉区的界面模式、界面字体、主题和颜色。设置搜索支持“字体平滑”“字体抗锯齿”和 `font smoothing`，进入同一主窗口的外观页并展开高级区。

沿用先落盘再发布的外观保存入口。失败时原偏好与文字渲染保持，保留错误和重试；选择相同值不重复保存。原生视图只更新绘制标志并请求重绘，不因这个开关重置文字、选区、撤销栈或中文组词。

| 应用自己的文字入口 | 偏好来源与处理 |
| --- | --- |
| 主/子输入器 `ComposerNativeTextView` | SwiftUI 外观环境；内容及占位符共同使用绘制作用域 |
| 设置多行编辑器 | SwiftUI 外观环境；保持启停、焦点、组词和占位符行为 |
| 文件编辑器 | SwiftUI 外观环境；保留原文字视图、选择和文件状态 |
| macOS 14 链接段落 | SwiftUI 外观环境；保持链接与原生选区 |
| PR Markdown 段落 | SwiftUI 外观环境；保持原生排版、链接与选区 |
| PR 标题/正文/评论编辑器 | SwiftUI 外观环境；内容和占位符共同绘制 |
| PR 审查表单编辑器 | 现有 presenter 的外观值；配置时更新，不替换编辑器 |
| 离线代码预览 | payload 写入根节点和 body，关闭移除行内值；保留 DOM、选区与滚动 |

七种原生入口共用 `AppearanceTextView` 的绘制边界。没有修改系统字体默认值，没有替换系统方法，也没有向用户浏览的外部网页注入样式。离线代码预览目前不是默认外观页的挂载内容，不能把其通过描述为外观页全部文字已经受开关控制。

## 验证记录

初次编译的新增测试夹具存在构造参数和异步断言写法错误，未产生通过结论，日志 `.cache/font-smoothing-initial-652.log`。修正夹具后，8 项专项通过，0 失败/跳过，2.776 秒，日志 `.cache/font-smoothing-repaired-652.log`。

专项覆盖公开参考输出、旧配置/主题往返/高级重置、保存失败/重试/重复值、三种界面模式的搜索、五种实际挂载文字视图在偏好切换后的身份/选区/撤销/组词、文件视图更新、Core Text 位图和状态恢复、真实 WebKit 行内值移除及选区保持。Core Text 位图在受控继承上下文中证明绘制策略生效，不能当成所有原生控件或参考应用的像素配对证据。

正式应用通过 `script/build_and_run.sh --app` 构建运行，日志 `.cache/font-smoothing-formal-run-652.log`。严格签名、IPC 及本机临时 HTTP 夹具的 Core RPC 冒烟均 exit 0，日志 `.cache/font-smoothing-signature-652.log`、`.cache/font-smoothing-ipc-652.log`、`.cache/font-smoothing-core-rpc-652.log`。没有 Rust 生产变化；正式 helper SHA-256 仍为 `380bec2aac119df2c9755850f1aa6150dd14cb9403a2eb8d42eff39e7f54ae9b`。

使用正式包 helper 的最终关联回归 **247 项、0 失败、0 跳过，124.702 秒**，日志 `.cache/font-smoothing-formal-associated-652.log`。范围包括外观/主题/设置导航与返回焦点、输入器、设置编辑器、旧版链接段落、PR Markdown/评论输入/审查表单以及文件查找和选区编辑请求；与 8 项专项有重叠，不累加。标准脚本重启亦 exit 0，日志 `.cache/font-smoothing-restart-652.log`。

前台实际操作确认：

1. 默认 `other` 工作区恢复可交互，没有持续恢复 loading。输入临时中文/Emoji 草稿后，⌘, 在 `ID: main` 内打开设置。
2. “字体平滑”搜索得到准确的外观结果，进入后高级区展开，开关默认开启，说明和行布局可见。
3. 实际鼠标点击、空格与 Return 均能切换；关闭时高级重置入口出现，开启后消失。Esc 返回原聊天并保留草稿及任务输入焦点。
4. 标准脚本重启后原草稿保持，英文 `font smoothing` 仍能定位同一设置；关闭状态保持，界面系统模式、界面字号 14、代码字号 12 及 Dock 默认图标保持。
5. 高级重置恢复字体平滑开启并移除重置入口；清空搜索、Esc 返回原输入。最后清理本轮临时草稿，恢复原本空输入和焦点，没有发送模型消息。

这些是 ShipiOS 原生前台操作证据，没有参考应用全页面双端配对证据。

## 未完成范围

SwiftUI 系统 `Text`、系统文本框与其他自绘文字控件仍未全部接入同等渲染作用域；所有字体/密度/主题下的实际像素和 VoiceOver 操作也未完整验证。条件空间图标、其余外观交互与完整双端配对继续保留。完整双端配对仍 **0/47**。

文件搜索的 400 毫秒间歇失败根因仍未确认。`fa27fc9` 固定全量的原 handle `76513` 已确认仍在运行，除原主题搜索断言失败外，又记录 5 个设置返回焦点用例失败；这些失败不由本阶段 247 项关联通过覆盖。焦点失败的套件顺序/窗口归属原因待查，不能直接归因于本轮字体改动或宣称已修复，也不代表最新源码全量通过。第 647 篇冻结的 55 个既有夹具、150 个资源、测试可执行文件和独立 helper 本阶段均校验未变；新夹具没有替换其资源。
