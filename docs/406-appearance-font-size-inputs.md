# 外观页的字号输入与保存

界面／代码字号改为 64×28 数字输入、右侧 px 单位与行内说明，替换原有步进器。输入和箭头操作只改变控件草稿；回车或失焦再保存，无效／越界输入恢复实际值。小数可以直接提交，step=1 只约束箭头网格。

## 参考事实与状态

参考为 Codex 26.911.61220 / build 9647 的公开分发资源。已逐字节核对安装包与缓存，未操作桌面、启动参考应用或读取个人配置／认证。`general-settings-ed7ca2006cd3.js` 的 SHA-256 为 `3a2ff568faaa71fa98cde8ca59a04d525baf13ce81a470ea8ae72c5283800753`；`app-initial-b21bd554b363.js` 为 `01c04b2e5a96e5dd4c97e02ffa183f571a55bef7a221abd99404246c430f2212`。

字号设置回调读取已被 HTML number 控件净化的 value，parseFloat 后按 schema 验证；失败恢复当前值，通过后写规范数字文本，仅不同值提交。输入为 compact、w-16、h-7、step=1、px，并按当前提交值作为 key。UI 默认 14、允许 11–16；代码默认 12、允许 8–24。没有整数 schema 限制，输入 13.25／8.5 可以保存。

原生 bridge 保留编辑器草稿，使用相同默认／范围和严格 HTML 数字语法；绑定写入后读取实际值，拒绝保存恢复字段与编辑器，不重建整份设置表单。正常值变更只重建该数字字段，旧控件不能迟到写入。marked text 不提交、不步进、不拦截回车；Tab 使用原生焦点移动，编辑中的 Esc 保留设置。字段受工作区加载／恢复、启停、隐藏及卸载范围保护。

界面和内容字体按基础字号 14 缩放并取整；代码字号保留小数，不改变已有代码字体与局部字号偏移。旧配置缺失字号时采用当前默认，已有显式 13 仍保存为 13；旧越界配置归一化到当前范围。此项调整影响字体测量，全部页面的文字层级与布局还须可见对照。

## 数字边界与原生验证

初次测试把 DOM stepUp／stepDown 当作用户箭头，产生 47 项步进差异。核对后确认这两个路径在空值／越界时不同，不能用 WebKit 的 DOM 方法证明 Codex 的 Chromium 用户交互相同。现在实际离线、非持久、无窗口 WKWebView 验证 44 种文本 × 2 种字段，共 88 组净化、保存、格式及共同的范围内网格；明确保留空值 DOM stepDown 不变而用户箭头起步到最小值的区别。

用户箭头另按 Chromium 的 [InputType](https://raw.githubusercontent.com/chromium/chromium/main/third_party/blink/renderer/core/html/forms/input_type.cc) 与 [StepRange](https://raw.githubusercontent.com/chromium/chromium/main/third_party/blink/renderer/core/html/forms/step_range.cc) 主线源码核对空值起步、上下界不循环、越界反向回到边界、保留不动的原文本，以及 step／2^24 的网格精度容差。不是当前 Codex 二进制内 Chromium 的实际运行验收。箭头按 [Chromium 默认样式](https://raw.githubusercontent.com/chromium/chromium/main/third_party/blink/renderer/core/html/resources/html.css) 仅在可编辑的悬停／聚焦状态显示，原生字段使用等宽数字并提供辅助功能上下界。

新增 14 项回归覆盖缺省和显式配置、小数持久化、88 组 HTML 结果、整数附近精度、字体缩放、草稿／回车／失焦／Tab／Esc、marked text、拒绝写入、正常值变化后的旧控件、失效与拆卸、实际 Appearance Form 的磁盘保存及失败保留，以及尺寸、单行长小数和辅助功能。尺寸测试发现 AppKit 对齐边距使字段变成 68 点，现去掉该对齐边距；编辑器左侧 8、宽 42、整体 64×28 的断言通过。悬停测试曾在主动失焦保存之后断言未写入，已改成分别验证失焦前草稿和失焦后的实际提交，未放宽保存或尺寸断言。

最后相关 Swift 回归 126 项全部通过（18.227 秒，`.cache/font-size-verified.log`）。较早 125 项通过集合及中间失败不重复计数；没有宣称整个测试包全量通过。

## 构建与剩余范围

正式应用经 `script/build_and_run.sh --build-app` 构建（Swift 2.57 秒），不启动或激活；严格深度签名通过。29 个高亮资源逐字节一致，引擎大小／哈希、manifest、26 个组件及主题目录核对通过。日志为 `.cache/font-size-app-build.log`、`.cache/font-size-package-signature.log` 和 `.cache/font-size-package-resources.log`。Rust 与高亮引擎未改动，不重复其完整测试；构建保留既有 Rust 警告。

当前 bridge 仍须核对输入过程的字符／粘贴与 locale 过滤、滚轮、箭头长按重复、平台缩放、真实 Tab 投递和关闭／重启的可见行为；系统材质、颜色和箭头字形也没有完成双端视觉验收。完整字体菜单／自定义输入、字体平滑、派生颜色、其余主界面与设置页继续在总范围内。源代码对照、隐藏窗口、离屏绘制和局部测试不能替代实际双端验收；完整配对仍为 0/45。
