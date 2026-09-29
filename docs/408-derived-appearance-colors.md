# 外观颜色派生与控件配色

外观现在按当前 Codex 分发代码派生颜色，背景保留原始 surface，正文使用 textForeground，侧栏使用 surfaceUnder。对比度改变控件、面板、边框和次要文字，取消此前直接改变背景、前景亮度的近似算法。字体和主题按钮、字号输入及同窗口菜单已接入各自实际使用的颜色角色。设置继续在主窗口内。

## 参考范围

参考安装包 Codex 26.911.61220 / build 9647 的公开分发资源，本轮未启动参考应用或读取个人状态。以下缓存与安装包内容逐字节一致：

| 资源 | SHA-256 |
| --- | --- |
| `app-initial-b21bd554b363.js` | `01c04b2e5a96e5dd4c97e02ffa183f571a55bef7a221abd99404246c430f2212` |
| `general-settings-ed7ca2006cd3.js` | `3a2ff568faaa71fa98cde8ca59a04d525baf13ce81a470ea8ae72c5283800753` |
| `app-30b4fba457b3.css` | `d5573a93b11a7826bf232e754d1b6353777d01c0bc067174f1701743537f9eea` |
| `button-5c1c3bb743c1.js` | `273d36683762281478f7663c4efc501366e8a7f497d2af38a0c6be1f48e44cda` |

实际执行分发代码中的主题派生和 CSS 导出函数生成测试期望，包含 43 个预设变体、浅深各 101 个对比度值、默认字段修改及自定义配色，共 303 组、51 个数值颜色角色、15,453 个颜色比对。公开资源与生成脚本仅在忽略的缓存目录；测试 fixture 只保存输入、颜色和资源哈希。

## 算法与接入

浅色对比度基准为 45，深色为 60；基准以上按参考的非线性公式放大。RGB 混合使用 sRGB 通道并按 JavaScript Math.round 舍入，透明度按 Number.toFixed(3) 的实际二进制输入舍入。默认深色仅在整个主题仍为默认时使用 `#dfdfdf` 正文；修改字体、透明度或语义色也会解除该特殊值，accentSource 本身不参与判断。强调色文字有参考的蓝色色相例外，不能只按亮度阈值决定黑白。

- 基础页面背景、正文、侧栏和每侧设置预览使用派生角色，未选颜色时也采用实际默认值。
- 字体、样式和代码主题按钮采用 outline 按钮的正文 2.5% 透明背景、secondary hover、border、borderFocus 和 tertiary chevron。悬停及展开状态触发重绘；绘制保留原颜色透明度。
- 字号输入采用 controlBackground、borderHeavy 和 borderFocus，保留 0.96 背景透明度。
- 同窗口菜单的 CSS `surface-elevated-secondary` 实际指向 controlBackgroundOpaque，使用 90% 透明度；选项悬停使用 buttonSecondaryBackgroundHover。不是按相似名字直接选择 elevatedSecondary。
- 颜色变化更新原控件和浮层，不重建字号编辑器，也不丢失草稿、选区、焦点和菜单身份。

51 个角色是派生模型覆盖范围，不代表所有页面中的按钮、边框和次要文字已经全部替换。账号强调色来源、其余 CSS color-mix 角色、原生材料与参考浏览器合成仍有差异。

## 验证

新增六项测试覆盖全部参考颜色、1,013 个透明度样例、对比度及蓝色例外、默认深色条件、离屏 sRGB 绘制，以及自有隐藏窗口中颜色更新时的编辑/菜单/持久化保护。窗口从未显示、激活或置前。

首轮 52 项测试中的离屏绘制用例有 59 条断言失败。诊断确认 CGImage 标记 sRGB、原始像素正确，但 NSBitmapImageRep.colorAt 返回校准 RGB，二次颜色转换改变数值。测试现通过 Core Graphics 转换到显式 sRGB RGBA 缓冲再读取像素，仍保留每通道 1/255 精度要求，未放宽断言或修改期望。

最终 143 项相关 Swift 回归全部通过，29.344 秒，日志 `.cache/derived-colors-verified.log`。包含六项新增测试及既有字体、字号、主题、菜单、设置导航、输入和窗口焦点用例；不是整个测试包全量通过的声明。

`script/build_and_run.sh --build-app` 正式构建通过，Swift 构建 2.54 秒；严格深度签名校验通过。29 个语法高亮资源与源目录逐字节一致，主题目录与工具目录一致，engine.js 8,861,982 字节、SHA-256 `b143d98543375763b5d44af62599180fa9afc0f9c8be8d683ef39d42234aa3a7`，manifest 保持 26 个组件。本轮未启动应用，不能声明启动或可见工作区验收通过。

## 剩余差异

字体平滑未实现。当前参考开启时使用 `-webkit-font-smoothing: antialiased`，关闭恢复默认；关闭不等于取消抗锯齿。[Chromium 的 macOS 字体实现](https://raw.githubusercontent.com/chromium/chromium/main/third_party/blink/renderer/platform/fonts/mac/font_platform_data_mac.mm)中 antialiased 保持抗锯齿并关闭 smoothing，auto 保留默认。[Core Graphics 的 smoothing 控制](https://developer.apple.com/documentation/coregraphics/cgcontext/setshouldsmoothfonts%28_%3A%29)属于具体绘图上下文，没有证据证明其可直接等效控制整个 SwiftUI 渲染树，因此没有添加无实际作用的开关。

全页面颜色角色接入、精确透明窗口与材料、菜单阴影、实际代码差异预览、字体目录/样式排序、数字输入过滤/滚轮/长按、输入法和全部可见双端配对仍缺。此次离屏绘制和隐藏控件测试不能替代逐页验收，完整配对仍为 **0/45**。
