# 设置菜单按钮表面与合并方式键盘入口

日期：2026-10-08。继续全部 UI／交互与核心功能对齐，修正共享下拉按钮的默认表面、长标题溢出，以及第 669 篇原生观察到的 Git“默认合并方式”被 Tab 跳过。

## 公开依据与实现

固定公开参考为 Codex 26.930.51102 / build 13100。`app-initial` 的 `wvs`（HD）默认使用共享 `dli`（ME）的 outline／toolbar 按钮及 Gxi（MS）向下图标。提取器 `extract_settings_menu_trigger.cjs` 执行实际组件的普通／带前导图形、启用／禁用四种分支，保存完整类名、图标路径和 CSS 数值；初始 JS、共享 JS、CSS 三项 SHA 固定在 `settings_menu_trigger_reference_670.json`。不是重新写一个参考函数，也不代表当前安装版本。

| 默认 toolbar trigger | 参考值 |
| --- | --- |
| 高度／文字／行高 | 28／13／18 点 |
| 普通左右内边距 | 12 点，外加各 1 点边框 |
| 带色样的前内边距／色样／内间距 | 3／20／6 点 |
| 文字组与箭头的间距／箭头框 | 4／14 点 |
| 普通标题之外的总宽度 | 44 点 |
| 带色样时标题之外的总宽度 | 61 点 |
| 默认圆角／外焦点轮廓／禁用透明度 | 10／2 点／0.4 |

色板引用按实际桌面级联解析：普通背景为 `--app-color-background-elevated-secondary`，hover／打开背景为 `--app-color-background-button-secondary-hover`，边框和箭头分别使用桌面的 border／text-foreground-tertiary。根主题曾存在前景色混合定义，不能取首次出现当成 Electron 最终背景。完整 CSS 的 WebKit 计算结果另外验证了尺寸、内边距、间距、字体、图标框和打开状态颜色。

- `SettingsMenuTriggerSurface` 绘制共享默认表面、图标及色样；`SettingsMenuControl` 保留原生 NSPopUpButton 的 first responder、可访问名称／值、菜单跟踪及目标动作。只给 SettingsMenuInput 开启新表面；其他动作菜单／分组菜单继续原样。
- 轻量 NSHostingView 只提供绘制，拒绝 hitTest、first responder 和键盘入口，并隐藏自身可访问内容，避免增加重复控件或 Tab 停靠点。原生真实聚焦、hover 和菜单 delegate 驱动表面，鼠标聚焦不额外显示键盘轮廓。
- 原生固有尺寸以当前标题及前导色样计算，Representable 遵守可用宽度；移除原先强制水平 fixedSize，长标题截断显示但菜单值／全称保持。缩窄不替换实际原生控件，焦点和选择保留。
- Git 默认合并方式迁移到相同共享菜单，保持原绑定、保存失败处理、搜索目标和真实枚举顺序；不执行任何 PR 合并或远端写入。

本阶段覆盖默认 outline／toolbar 分支。公开参考另有 menuRow、full radius、outlineSurface 和固定宽度等调用变体，尚未全部映射；原生 popup 的位置、动效与浏览器菜单也未宣称相同。10 点是基础圆角，支持 superellipse 时的半径比例与原生连续圆角仍需另行核对。

## 验证证据

旧实现 `.cache/settings-menu-trigger-before-670.log`：3 项、12 条失败，分别暴露实际 24 点高度／宽度、长中文标题越界和找不到可聚焦共享 Git 合并菜单。新关联 `.cache/settings-menu-trigger-associated-670.log`：21 项、0 失败／跳过。

新增完整 CSS／原生像素验证最初因测试颜色结构字段写错编译失败（`.cache/settings-menu-trigger-rendering-670.log`）；修正为实际 red／green／blue／alpha 字段后，`.cache/settings-menu-trigger-rendering-fixed-670.log` **23 项、0 失败／跳过**。没有为此改变生产颜色或放宽原生断言。

原生几何用例覆盖有／无色样、双方向、三次长标题缩窄、选择与 first responder；真实 Git 页用例验证共享控件、值落盘与搜索回路。像素用例检查实际控件正常／菜单打开／关闭／禁用、焦点外轮廓及旧焦点释放，扩大回归还包含真实 AppKit mouseEntered／mouseExited 回调。完整 CSS 用例需要本地固定 `SHIPIOS_REFERENCE_CSS` 并核对 SHA；没有该资源时明确跳过外部样式验证，其他原生用例仍运行。本机最终扩大验证显式提供该完整资源。

最终扩大回归 `.cache/settings-menu-final-expanded-670.log` **481 项、0 失败／跳过**，140.652 秒，2026-10-08 17:56:54.646 结束，exit 0。完整 CSS 资源已显式传入。查看生成的通用与 Git 设置快照，未见标题／箭头越界；快照不代替双端配对。

正式脚本启动后实际操作 24 个设置导航页和技能／MCP 两个插件子页，始终为 ID main。Git 从分支前缀四次 Tab 到达默认合并菜单，Return 打开、下键／Return 选择压缩合并并落盘；Tab 到下一开关、Shift-Tab 返回、空格打开及 Esc 取消通过。元素点击也能打开菜单；该工具调用可能使用 AXPress，不能据此证明真实指针 hover 或鼠标聚焦轮廓。API 协议菜单方向键打开、Esc 取消及 Tab 到空密码字段通过，未填写凭证、保存模型配置或请求真实服务。

标准脚本重启隔离工作区后，实际主窗口恢复任务“设置焦点验收670”和草稿“设置焦点原生验收草稿670”；Git 仍为压缩合并，四次 Tab／Return／Esc／Tab 再验通过，中文 PR 监控指令保留。退出设置后输入获得焦点、草稿未变。最后恢复默认 other 工作区，点击输入、⌘,、Esc 后仍在 ID main，实际输入获得焦点，无持续恢复 loading。日志 `.cache/settings-menu-native-{run,restart,restart-final}-670.log`、`.cache/settings-menu-default-run-670.log`；实际交互摘要另存 `.cache/settings-menu-native-evidence-670.json`。

保存 helper SHA-256 `d783e1eac53ff254064f4c64f068b8d036f12079994253c459846f05f970d6a2`，IPC／Core 本机回环冒烟均 exit 0，日志 `.cache/settings-menu-{ipc,core}-670.log`。最终严格深度签名通过，保存／捆绑 helper 的 CDHash 一致，见 `.cache/settings-menu-final-signature-670.log`、`.cache/settings-menu-code-equivalence-670.json`。无 Rust 源码改动，不声称重跑 Rust 全套或真实用户服务。

## 已结束的旧全量与剩余范围

2026-10-08 19:27:20，第 670 篇冻结提交 `a4068692811f31111c3a71a58f7ff5b7eef10a97` 的原 handle 50465 取得 exit 0：**2,890 项 Swift、2 跳过、0 失败**，4,640.535 秒，随后 IPC exit 0。两项跳过仍为未配置本地音频夹具地址的 RealtimeVoiceWireTests；离线语法记录一次冷启动恢复，实际参考 token 比对仍通过，并非跳过该用例。终态重新核对 73 个源夹具、166 个捆绑资源、测试执行文件、保存 helper 及完整参考 CSS 均未变化，保存 `.cache/full-alignment-regression-670-final-audit.json`；日志、manifest／status 同前缀。后续代码使用另一缓存开发，没有重启此进程；该完整结果覆盖冻结的第 670 篇，不覆盖第 671—673 篇及之后的签名修复。

第 666 篇冻结提交 9336030 的完整回归已取得原 handle 94550 的 exit 0：**2,878 项 Swift、2 跳过、0 失败**，4,602.747 秒，2026-10-08 17:49:21.498 结束；随后 IPC exit 0，runner finishedAt 09:49:22.004786 UTC。两个跳过为未配置本地音频夹具地址的 RealtimeVoiceWireTests。无 cold syntax recovery。日志、manifest／status 为 `.cache/full-alignment-regression-666-*`；终态核对 70 个源夹具、163 个资源、测试执行文件和 helper 均未变化，另保存 final-audit。这个结果不覆盖第 667—670 篇。

仍需继续所有菜单变体、精确字重／字形／视觉和动效、其他原生 Picker／滑杆／字号步进器、全部激活与失焦来源、macOS 14 实际运行、真实用户服务，以及每页所有行为。Codex 窗口操作此前受工具安全限制，没有绕过。完整范围仍为 21 个主页面／交互类别、26 个设置面及 29 项核心功能，完整双端配对 **0/47**，不是代码完成比例。见[完整矩阵](599-core-function-parity-matrix.md)。
