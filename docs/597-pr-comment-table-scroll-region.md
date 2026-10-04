# PR 普通表格：溢出区域、键盘与无障碍

本阶段接续[表格预览](596-pr-comment-table-preview.md)，补齐普通表格滚动区域的焦点和无障碍行为。不是完整页面或像素对齐验收。

参考为当前已安装版本 26.930.21537 的公开 `LJc` 组件。它只有在 `scrollWidth > clientWidth` 时给表格滚动容器设置 `role=region`、可滚动表格标签及 `tabIndex=0`，非溢出时三者都不设置。复制按钮绑定水平滚动处理器，展开按钮不绑定；展开有 `aria-haspopup=dialog` 和 `aria-expanded`。参考哈希与本地夹具事实见 `pr_comment_table_scroll_reference.json`。

通过 CUA 在本地浏览器夹具操作得到：溢出时 Before → 区域 → Copy → Expand → After；非溢出时 Before 直接进入 Copy。区域普通右键从 0 到 40，Option＋右键仍为 40；在 Copy 按 Option＋右键则从 40 到 240（视口宽 200）。这些是公开属性及复制处理器的局部夹具证据，不能替代真实 Codex 前台操作。

原通用 SwiftUI ScrollView 无法精确控制是否进入原生 key-view loop，因此新增一个只用于 PR 表格的 `NSScrollView` 桥接，表格内容继续使用既有 SwiftUI 布局。它按真实内容测量更新高度，保留外观、颜色方案、启用状态、链接打开、相对图片读取及 PR revision。旧正文或宽度的迟到测量不会更新新文档；卸载后移除滚动锚点，复制工具栏不能再操作旧页面。

溢出区域以有标签的 AXGroup 暴露，只有溢出、已挂载、已启用且没有所属窗口模态阻挡时可成为第一响应者。普通方向键每次滚动 40 点，边界钳制且保留纵向位置；修饰方向键不冒充复制按钮的整页快捷键。非溢出时不暴露命名区域，也不隐藏正文；若区域正持有焦点，则移到下一个有效控件并清零横向位置。普通文字单元格不再逐个占 Tab 停靠点，鼠标选择仍保留；含链接单元格保留既有原生文字焦点，逐链接焦点还需后续实现。

原生窗口实际 `selectNextKeyView` / `selectPreviousKeyView` 测试覆盖 Before、区域、复制、展开和 After 的顺序。区域焦点不会被误认为工具栏 focus-within。展开按钮现暴露 AXPopUpButton，辅助功能展开动作进入所属窗口内预览；预览的滚动容器也使用与 `role=region` 相应的 AXGroup。

新增 8 项原生滚动区专项覆盖焦点顺序、非溢出跳过、修饰键、边界、缩放选区、正文替换、窗口模态/禁用/卸载、链接和图片 revision。初次 84 项关联回归有一条链接测试夹具失败：绕开 SwiftUI 状态直接替换 native root 后，被父视图的原文重绘覆盖；夹具改为通过实际状态和继承的 OpenURL 更新，不改变断言以掩盖结果。之后 35 项专项复测通过，最后源码与启用状态传递修正后的 **97 项关联回归全部通过**（`.cache/pr-table-scroll-regressions-final.log`），没有布局循环警告。

`.cache/pr-table-scroll-renders/short.png` 已实际查看，表格文字、列定位和分隔可见；透明离屏捕获不能证明主题背景或像素完全相同。最终源码经 `script/build_and_run.sh` 正式构建及启动命令成功（`.cache/pr-table-scroll-app-run.log`），严格签名验证通过（`.cache/pr-table-scroll-signature.log`）。随后 CUA 读取新包仍返回 Mac 锁屏，实际工作区可交互未确认。没有把启动命令成功当作启动验收。临时浏览器夹具和本机服务将在提交前清理。完整双端配对仍为 **0/47**。尚未完成：字体自然列宽差异、横向溢出渐隐、逐链接与复杂媒体/HTML 的焦点及无障碍、轮廓/图标/阴影像素、全页面双端配对。
