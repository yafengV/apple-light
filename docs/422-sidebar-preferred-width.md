# 主窗口与设置侧栏首选宽度

当前 Codex 桌面分发样式把侧栏宽度定义为 `clamp(240px, var(--codex-sidebar-preferred-width, 275px), min(520px, calc(100vw - 320px)))`，设置页使用同一 `w-token-sidebar` 宽度。参考文件为本地分发的 `app-30b4fba457b3.css`（SHA-256 `d5573a93b11a7826bf232e754d1b6353777d01c0bc067174f1701743537f9eea`）及 `app-initial-b21bd554b363.js`（SHA-256 `01c04b2e5a96e5dd4c97e02ffa183f571a55bef7a221abd99404246c430f2212`）。

ShipiOS 此前设置侧栏固定为 220pt，工作区侧栏首选为 245pt。现在设置侧栏为 275pt；工作区 `NavigationSplitView` 采用 240pt 下限、275pt 首选、520pt 上限。隐藏的 1100pt 原生窗口测得详情列相对根视图偏移 283pt，其中包含原生分隔区域；回归测试约束该偏移。最小 960pt 窗口下已离屏渲染并检查设置页，许可子页另外检查单一滚动文档和有效图像。

最终 265 项相关 Swift 回归全部通过，日志 `.cache/sidebar-width-regression.log`；调整后的 20 项设置布局与导航定向测试也通过，日志 `.cache/sidebar-width-targeted-final.log`。`script/build_and_run.sh --build-app` 成功，日志 `.cache/sidebar-width-build.log`；严格深度签名通过，正式包的 29 个语法资源和七份许可证与源文件逐字节一致。

这一调整只处理侧栏尺寸。Codex 的 CSS 在窄窗口还会按视口宽度缩小侧栏，ShipiOS 的主窗口最小宽度目前为 960pt，因此本阶段没有对应窄窗口场景。本阶段没有进行可见窗口启动及双端逐页、逐交互验收；离屏渲染和自动化测试不能替代它们，完整配对保持 **0/45**。
