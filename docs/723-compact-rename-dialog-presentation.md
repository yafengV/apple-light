# 重命名弹层尺寸、样式与键盘顺序

日期：2026-10-09。接续[固定侧栏重命名](721-pinned-browser-rename-dialog.md)。任务与固定浏览器标签继续使用当前窗口内容内的同一弹层，不创建独立设置或改名窗口。

## 固定参考与实现

依据已保存的 Codex 26.930.51102／build 13100 初始资源、共享组件及共享 CSS。`script/extract_rename_dialog.cjs` 对三份资源检查 SHA-256，执行实际 `Cvo`、`qbi`、`uxi`、`dxi`、`mxi`、`fxi` 和 `dli`，保存四组空／非空输入与允许／禁止空值的表单树、实际 medium 按钮类和 CSS 指标。React 状态／引用／memo、国际化、JSX 和元数据均使用明确的无副作用替身；没有读取 Codex 当前窗口、配置或会话，没有运行 Radix 或其真实 DOM。焦点参考来自表单中可用控件及源代码中 body 后面的关闭按钮顺序，不作为参考应用真实键盘验收。

| 项目 | 原实现 | 本次实现及参考 |
| --- | --- | --- |
| 宽度／窄窗口 | 440／92% | 420／92% |
| 内容内边距／段间距 | 24／16 | 20／12 |
| 标题／说明 | 17 号标题、默认说明 | 20／28 行高、14／21 行高、间距 4 |
| 输入 | 系统 roundedBorder | 高 36、13 号字、水平 padding 10 加边框 1、应用主题背景及边框 |
| 操作按钮 | 系统按钮和强调色 | medium 高 32、14 号字／18 行高、水平 padding 16 加边框 1、间距 12、outline／primary 主题角色 |
| 遮罩 | 黑色 0.3 | CSS `#0002`，即 2/15 |
| 关闭按钮 | 占标题行、无循环焦点 | 高宽 24，顶／右 16，位于正文之后，RTL 仍保持物理右侧 |
| 键盘循环 | 名称、取消、保存 | 名称、取消、保存、关闭；保存禁用时略过它，正反向循环 |
| 关闭按钮 Enter | 误走保存 | 与取消一样关闭；名称／保存继续提交 |
| 空格激活 | down 即执行 | down 准备、up 执行一次，重复按下不重触发，失焦／禁用／窗口失去 key／拆除取消准备 |

新组件保留应用字体和浅深主题配置。保存背景、前景、outline 背景、hover、输入背景及粗边框使用参考 CSS 对应的应用主题角色；表面使用 elevatedSecondaryOpaque 90% 叠加原生材质。native continuous 曲线、材质、阴影、系统字形与参考 CSS 的 superellipse(1.5)／backdrop blur 并不由这次测试证明相同。CSS 支持 superellipse 时半径会乘 1.25；本次采用 CSS 圆角 fallback 尺寸，精确曲线仍待双端验收。

## 测试与失败修复

首轮专项 20 项有 8 条失败断言。RTL 的关闭按钮确实被 SwiftUI 镜像，已将定位容器显式设为 LTR；不是放宽该断言。标题探针原先只测到自然文本宽度，标题组件改为与参考 flex-1／self-stretch 一致地占满内容宽度。AppKit 文本框 bounds 含系统 alignment 补偿，输入测量改用其真实 alignmentRect，保留参考的 10+1 padding 断言。

修正后专项 **20 项、0 失败／跳过，4.436 秒**；扩大 **335 项、0 失败／跳过，22.162 秒**。新增实际原生 surface／标题／按钮几何测量覆盖正常及窄窗口、LTR／RTL；真实任务和浏览器弹层挂载后核对可编辑初值、字体及输入 alignment 宽度。焦点循环及 Space 状态测试证明路由和释放语义，不证明系统已给窗口 key 或真实焦点已移动。扩大范围包含第 721 篇关联范围、任务改名及设置按钮回归；数量重叠，不相加。沿用第 721 篇窗口方法排除，尤其没有把仍失败的 `PinnedBrowserRenameTests.testNativeActualMainMountsSidebarModalInsideExistingWindowAndInlineEditorBlurSaves` 记为通过。输入、执行文件及编译资源摘要前后未变化，参考重新提取后逐字节一致。

首轮／修正日志分别是 `.cache/rename-dialog-focused-723.log`、`.cache/rename-dialog-focused-repaired-723.log`；扩大日志和清单为 `.cache/rename-dialog-expanded-723.log`、`.cache/rename-dialog-expanded-provenance-723.json`。扩大编排第一次误将 prior manifest 路径写成尚不存在的新输出，未启动测试就失败；修正后读取原第 721 篇清单并取得上述终态，没有覆盖原记录。

## 打包及剩余范围

标准 `script/build_and_run.sh --build-app` exit 0，Swift 构建 3.01 秒；正式应用与 helper 均使用 Apple Development，指定要求保持第 713 篇基线，旧要求及严格深度校验通过，包内 helper IPC exit 0。打包前后 1,634 项源码、测试、执行文件及编译资源摘要未变。日志／清单为 `.cache/rename-dialog-{build-run-final,signature-final,package-final-provenance,ipc-final}-723.*`。Mac 最近明确锁屏，本阶段未启动新包进行前台点击，不把构建或隐藏挂载称为可交互工作区验收。独立固定第 721 篇广泛回归仍有活跃监督及 Swift 测试进程，构建与预检 exit 0，当前执行全部其他 Swift 方法，仍无终态；不包含本篇改动。

仍需真实双端焦点、自动全选、Tab／Shift-Tab／Enter／Space／Esc、输入法、指针、主题颜色／字形／圆角／阴影／材质、窄屏 footer 换行、任务空名称的 invalid 视觉态、错误及保存状态验收。固定侧栏全部来源 phase、其余浏览器动作、关闭菜单与返回焦点、图标／状态／缩略图／行布局仍属于原范围。完整范围保持 **47 页面、29 核心项、完整双端配对 0/47**，此阶段不换算完成百分比。
