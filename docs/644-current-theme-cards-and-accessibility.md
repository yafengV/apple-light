# 当前主题卡片与原生辅助功能

日期：2026-10-07。范围为外观页的系统、浅色、深色选择器，继续保留 21 类主界面、26 类设置及 29 项核心要求；完整双端配对仍为 **0/47**。

## 实际问题与当前参考

正式包前台的“主题”原先只有一个空的可访问分组，三个自绘 NSControl 均未出现在树中。原测试直接调用对象的 accessibilityPerformPress，不能发现这个缺口。新增原生完整页面测试通过实际 accessibilityChildren 和 unignoredChildren 查找选项；旧实现一项测试出现四条失败断言，日志 `.cache/theme-accessibility-before-644.log`，exit 1。

重新读取 `/Applications/ChatGPT.app` 的公开静态分发资源，确认当前版本为 26.930.51102 / build 13100，没有读取个人配置、认证、会话或操作其前台。当前 general-settings-4f1402fc1fbd.js 的 SHA-256 为 91ef510e7631785df4c62c25f3b9018a0ca3c15ce3fa1b208f3cf8394abdf535。

实际 Ys/ac/oc 组件使用 radiogroup、同名原生 radio 输入和独立可访问名称；分组 grid w-68/max-w-full/gap-4，卡片 aspect-4/3，名称通过 tooltip 提供，没有可见文字标签。选中和未选中均为 2 像素边框，焦点轮廓为 2 像素、向外间隔 2。当前公共 CSS app-shared-6fb15e58cd7f.css（SHA-256 4ea4b25e3f4f3225a3bf212fa767afe7655b16bbd5919ebf4fb12c656f974720）确认 spacing .25rem、桌面 text-info/ring 使用应用主题角色。

第 412 篇的 170×120、可见标签和宽卡片来自更早版本，不能继续作为当前选择器的要求。原 24 组夹具保留为历史分区/示例记录，相关测试已明确命名为 Historical；本阶段新增独立 theme_card_reference_644.json，没有修改旧全量所用的夹具。

## 实现与素材

- 显式暴露三个原生 Radio；保留顺序、中文名称、选中值和实际启用状态。选中值变化发送原生 valueChanged 通知。
- 总宽度上限 272、列间距 16、预览 4:3，使用当前四份 SVG（浅、深、系统左/右）。移除旧可见标签，保留悬停名称、单组选中 Tab 入口、方向键环绕、空格及统一激活路径。
- 使用当前主题的 textAccent、borderFocus、border/borderHeavy；外侧焦点轮廓允许越过控件边界，失焦重绘旧轮廓。保存失败、恢复中、卸载、隐藏页面和模态保护沿用实际状态检查。
- 新资源目录 ThemePreviews 包含原始 SVG、WebKit 生成的中性底图和强调色蒙版。PNG 是正式界面素材，分别提供 1×/2×/3×，运行时无需新增 WebKit 页面。独立颜色缓存保持自定义强调色，系统模式使用真实左右半图。

直接由 AppKit 解码 SVG 时，像素对照发现 filter 阴影缺失，一组 10 项测试有 78 条失败断言，日志 `.cache/theme-current-layout-644.log`。仅使用 3× 底图缩小仍有细线和圆角偏差，62 条失败断言，日志 `.cache/theme-render-after-644.log`。最终补齐三种原生密度，没有删除采样点或放宽 3/255 门槛。

提取过程保存为 script/extract_theme_card_reference.mjs，只执行选定的公开叶子组件；script/render_theme_previews.swift 使用无窗口、非持久 WebKit 离线生成素材。资源 PROVENANCE.md 记录四份 SVG 的 SHA-256 与来源。原素材归 OpenAI，不把 Core 的 Apache 许可证当成桌面素材授权证明。

## 最终验证

本阶段 Rust 生产代码未变。正式 helper SHA-256 为 380bec2aac119df2c9755850f1aa6150dd14cb9403a2eb8d42eff39e7f54ae9b，与第 643 篇冻结 helper 相同。

- 最终 **125 项、0 失败/跳过、52.343 秒、exit 0**，日志 `.cache/theme-formal-associated-644.log`。范围 Appearance、ThemeCardReferenceTests、SettingsReturnFocusTests、CommandSearchDialogTests。先前 123/125 项集合与此集合重叠，不累加。
- 972 个采样点覆盖三种模式、两种强调色、1×/2×/3×；将实际参考 JSX 的 SVG 经 WebKit Canvas 绘制，与最终原生绘制的 sRGB 缓冲比较。每通道误差不超过 3/255。该检查不等于整页逐像素配对。
- 实际分发组件的卡片结构、选项顺序及 checked 状态、四份 SVG 哈希、24 份 PNG 的密度/透明通道、原生资源解码和独立颜色缓存通过。原生页面覆盖可访问分组子项、选择/状态/启用、失败保存、恢复/卸载、键盘、草稿和窗口布局。
- 正式脚本构建运行、严格签名、明确包内 helper 的 IPC 和 Core RPC 冒烟通过，日志 `.cache/theme-formal-run-644.log`、`.cache/theme-signature-644.log`、`.cache/theme-ipc-644.log`、`.cache/theme-core-rpc-644.log`。

正式包在既有隔离工作区前台验证：主窗口 ID main 中进入外观，三个 radio 独立可见，实际预览及外侧焦点轮廓可见；点击浅色、Right 到深色、Right 环绕系统、Left 环绕深色、空格、Tab 离开及 Shift-Tab 返回深色均核验。切换后显示相应浅/深配置，父回复和子历史保持。

选择浅色返回原子输入，确认焦点后键入 -theme644 仅追加原子草稿。一次将 Escape 与输入连续批量发送时未追加文字；该次不计直接键入验收，也不据此宣称快速连续按键边界已解决。随后确认返回焦点再输入取得实际成功证据。通过正式脚本重启后，浅色 radio 值仍为 1，子草稿含 -theme644，父输入仍空。没有发送模型请求。隔离主题已恢复原 system；重启日志 `.cache/theme-restart-run-644.log`。

随后通过正式脚本恢复默认 other 工作区，日志 `.cache/theme-default-run-644.log`；实际点击父输入、⌘, 打开设置、Esc 返回，同一 main 窗口且父输入重新聚焦，无持续恢复 loading。

## 全量与剩余

第 643 篇固定提交 21dad308b48ec4cfdc1f17c2216166fb014e92d4 的全量 session 5404 已重新确认仍 live，未重启或替换。它的 helper、测试二进制、16 份既有夹具及 87 份打包资源哈希均保持。它不覆盖本阶段新源码、夹具和素材；第 639 篇 2,758 项、2 跳过、0 失败及 IPC 的旧终态结论保留。

外观页当前高级配置展开/折叠、字体/数字/对比度控件的前台辅助功能、其余颜色/材料/尺寸与整页交互继续核对；VoiceOver 实际播报及快速连续返回输入亦未完整验收。子任务其他权限、V2/其余恢复、补丁审批偶发超时根因以及矩阵全部剩余项继续未完成。完整配对不增加。
