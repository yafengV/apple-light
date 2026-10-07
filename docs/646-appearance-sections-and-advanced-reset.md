# 当前外观分区与高级重置

日期：2026-10-07。接续第 645 篇。范围保持 21 类主窗口、26 类设置、29 项核心要求，完整双端配对 **0/47**。

## 当前参考证据

重新检查公开分发的 `/Applications/ChatGPT.app`：26.930.51102 / build 13100。没有操作 Codex 自身，也没有读取个人认证、配置或历史。

- `general-settings-4f1402fc1fbd.js` SHA-256：`91ef510e7631785df4c62c25f3b9018a0ca3c15ce3fa1b208f3cf8394abdf535`。
- `app-initial-f9b16fbf8fc7.js` SHA-256：`22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3`。
- `Ms`：Visual style / Advanced；Advanced 默认折叠，字号、动态效果、独立模式、每侧高级字体/透明度/对比度及指针/差异设置在其内部。
- `Ia`：默认只显示有效色板；独立模式开启后显示浅、深两侧。该开关是页面局部状态，不写偏好。
- `La`：UI family 在 visual，UI style 在 advanced；content/code 在 advanced 同时显示 family/style。当前整页没有旧版独立代码预览。
- `No` / `kRs` / `BRs`：高级重置关闭独立模式，恢复全局高级偏好和两侧 contrast/opaqueWindows/content/code/UI face，保留模式、UI family、预设、颜色和 semantic colors。

`script/extract_appearance_advanced_reference.cjs` 只在带模拟依赖的 VM 内计算选定公开 JSX/重置函数，不执行原应用。输入固定哈希，生成 `appearance_advanced_reference_646.json` 的 24 种模式/系统色/独立模式/展开组合和四种两侧/背景支持重置结果。重新生成与夹具逐字节相同。原生 Mac 当前支持透明背景；不把不支持背景的平台夹具描述为该平台实机测试。

## 实现

- 页面分为“视觉风格”和可折叠“高级”；模式进入带标签的卡片，默认只挂载有效色板。UI 字体家族与样式分区，移除当前页面的旧版代码预览；独立预览组件测试仍保留。
- 页面局部 `AppearancePagePresentation` 管理展开与独立模式；切离/重新进入设置和搜索导航通过路由身份重建。偏好文件不保存这两个字段。
- 高级重置独立于是否展开；同时恢复已实现的两侧高级值及旧版全局代码字体，保留视觉值。工作区原子保存失败保留原偏好和错误，重试可保存；独立模式按参考在尝试重置时先关闭。
- 导入/复制改为带辅助功能标签与提示的图标入口；高级按钮加入同窗口导入确认开始阶段的保护。字体菜单和高级内容移除时保留既有清理。
- 分别显示浅深模式时，另一色板的导入不切换模式。原模式资格检查会拒绝该入口，现以附着窗口的真实入口建立独立模式导入会话；模式改变使旧会话失效，不能提交过期回调。
- 搜索只提供默认有效色板的目标，并加入高级/独立模式/UI 样式目标；兼容的旧字体/导入路由映射到有效色板，不改变持久主题。当前参考对整套搜索呈现的完整配对仍未取得。

## 测试证据

初次构建被沙箱的模块缓存写入限制阻止，升级后开始构建；一轮因构建期间源文件变化失败，后续不再并发改编译输入。Swift 长条件表达式拆开后编译通过。

首轮关联 148 项、19 条失败（含一个 unexpected），日志 `.cache/appearance-associated-final-646.log`：旧页面假设默认全展开/双色板/代码预览，以及高级按钮模态开始阶段保护缺失。保留原测试目的，将双色板/全控件夹具显式展开并启用独立模式；默认与展开的真实挂载另由新增测试验证，旧预览验证保留到独立组件。

第二轮 149 项、4 条失败，日志 `.cache/appearance-associated-final2-646.log`：均为主题图片缓存对象身份断言。`NSCache` 不能保证持续保留对象；不据此宣称应用缓存故障或已定位内存压力根因。改为比较同强调色实际 TIFF 输出相同、不同强调色实际输出不同，原有素材哈希、像素尺寸和透明度检查保留。

第三轮 **149 项、0 失败/跳过、55.543 秒、exit 0**，日志 `.cache/appearance-associated-final3-646.log`。随后补充实际 RuntimeSettingsView 容器的切页返回、退出重进与搜索重建用例；最终 **150 项、0 失败/跳过、59.115 秒、exit 0**，日志 `.cache/appearance-final-associated-646.log`。两轮集合重叠，不累加。覆盖 Appearance、SettingsNavigationTests、ThemeCardReferenceTests、ShipiOSResourceBundleTests、SettingsReturnFocusTests，包含七项新增用例：当前分发参照、视觉值保留、原生展开/折叠/独立色板、重置失败/重试、搜索入口、非生效色板导入与失效，以及真实设置容器路由重建。隐藏窗口叶子测试不冒充前台完整可访问树。

标准脚本的隔离正式构建/启动 exit 0：`.cache/appearance-formal-run-646.log`。严格深度签名与 IPC exit 0：`.cache/appearance-signature-646.log`、`.cache/appearance-ipc-646.log`。helper SHA-256 保持 `380bec2aac119df2c9755850f1aa6150dd14cb9403a2eb8d42eff39e7f54ae9b`。Core 冒烟 `.cache/appearance-core-rpc-646.log` 同样 exit 0，覆盖本机审批、提问、引导、工作区写入、隔离和凭据清理；没有真实外部 API 请求。

## 原生验收与剩余

正式启动后 CUA 明确返回 Mac locked，自动解锁失败，已请求用户手动解锁。之后按标准脚本恢复默认数据目录，`.cache/appearance-default-run-646.log` 与最终严格签名 `.cache/appearance-default-signature-646.log` 均 exit 0；再次 CUA 仍明确锁屏。隔离验收数据中的外观与操作前基线完全一致。

因此本阶段展开/折叠、开关、重置、搜索滚动、切页和重启后的实际页面/焦点验收仍缺；不能把构建、隐藏窗口或进程存在称为工作区可交互。本阶段开始前旧正式版本默认工作区读取正常，不证明新版本。

字体平滑、Dock 图标选择、VoiceOver 实际播报、完整输入时序、字体排序、菜单箭头/阴影、全页材料/颜色/间距及双端配对仍缺。当前公开 Mac 字体平滑作用为 CSS `-webkit-font-smoothing: antialiased`；不以无实际等效效果的勾选框冒充原生支持。

第 643 篇固定提交 `21dad308b48ec4cfdc1f17c2216166fb014e92d4` 的原 session 5404 已终态 **exit 1**：2,773 项 Swift、2 跳过、1 unexpected failure、4,529.905 秒，失败为 `WorkspaceFileSearchSessionTests.testPartialResultsKeepAWorkingSearchAlive` 的文件搜索超时。状态 `.cache/full-alignment-regression-643-status.json` 与完整日志一致，未重启；105 个冻结输入哈希保持。该 runner 在 Swift 失败后未执行其后 IPC，不将本阶段单独 IPC 冒烟填作该全量通过；失败根因待单独定位。该全量不覆盖本阶段。第 639 篇固定全量 2,758 项、2 跳过、0 失败及 IPC 保持为旧版本证据。

子任务其余权限/V2 恢复、审批偶发超时根因以及其余矩阵范围保持。目标仍未完成。
