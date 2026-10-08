# 聊天顺序、内容标签与最近访问切换

日期：2026-10-09。接续第 690 篇已确认的导航命令合并错误，恢复六种独立命令及最近访问切换的按住生命周期。本阶段是代码和回归验证，不能计为整页或双端交互验收完成。

## 参考证据与命令区分

参考当前本机公开静态资源 `app-initial-f9b16fbf8fc7.js`（26.930.51102、build 13100，SHA-256 `22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3`）。`script/extract_task_navigation.cjs` 校验完整源哈希，提取六个命令字面量、实际 `hSs`／`fSs` 最近访问状态函数、`dcc` 松开键集合、`mLa`／`hLa` 顺序导航、`swa` 统一标签选择和 `Kqr` 共享绑定对。顺序导航使用无副作用的注册／状态占位对象，标签选择使用显式提供的布局／原子与空焦点钩子执行原函数；不启动参考应用，不访问原生桥接、账号或用户会话。

| 参考命令 | ShipiOS 命令 | 默认绑定 | 命令菜单 |
| --- | --- | --- | --- |
| `previousThread` | `previous-task` | ⌘⇧[、⌘⌥← | 显示 |
| `nextThread` | `next-task` | ⌘⇧]、⌘⌥→ | 显示 |
| `previousTab` | `previous-tab` | ⌃⇧Tab、⌘⇧[、⌘⌥← | 隐藏 |
| `nextTab` | `next-tab` | ⌃Tab、⌘⇧]、⌘⌥→ | 隐藏 |
| `previousRecentThread` | `previous-recent-task` | ⌃⇧Tab | 隐藏 |
| `nextRecentThread` | `next-recent-task` | ⌃Tab | 隐藏 |

同方向标签命令可以分别与聊天顺序、最近访问命令共享绑定，共四对；聊天顺序与最近访问彼此仍冲突，反方向也仍冲突。设置页保留六条可独立编辑的命令；命令搜索不展示参考中 `commandMenu` 关闭的四条。原生标签菜单使用标签命令；按键由窗口路由处理，避免原生菜单提前提交按住选择。

## 实现行为

- 聊天顺序使用当前侧边栏可见顺序，到首尾停止；无当前任务时从首／尾开始，找不到当前任务时保持不动。它不再兼任文件、浏览器或内容标签切换。
- 最近访问使用访问历史，不复用命令菜单中排除置顶／当前项并优先未读的“最近任务”列表。开始按住时将当前任务放在首位，冻结顺序，重复按键和反向按键循环移动暂选；访问历史最多保留 20 项。
- 按下期间不打开任务、不写访问记录、不改变草稿。松开最初触发组合中的任意 Control／Command／Option 才提交；Shift 不属于提交键。无这些修饰键时由触发键的 key-up 提交。被删除／归档、路由已变化或交互被阻止的候选不迟到打开。
- 主窗口与独立任务窗口各自持有控制器。独立任务窗口提交到自己的 `onNavigate`，不直接改变主窗口选择。窗口失焦、关闭、应用失活、桥接移除、模态及录制阻止会取消暂选。
- 共享按键先交给符合焦点条件的内容面板；内容面板不能切换时继续最近访问流程。旧文件和浏览器监视器不再抢先把 Ctrl+Tab 当作即时任务切换。全屏内容使用聊天／内容统一顺序，侧面板和底部面板按焦点处理，排除分离标签。独立窗口标签切换失败后继续聊天顺序路由，不再二次命中不可执行的标签命令；旧浏览器仅在当前任务标签内循环。全屏／分屏／主次交换的全部参考状态仍需进一步逐项核对，见剩余边界。
- 顺序聊天命令不接受重复 key-down；最近访问及标签切换接受重复。原生文本输入法组合态与全局模态窗口阻止新导航。
- 参考 `tcc` 只提供读屏状态，没有可证明的视觉选择弹窗；当前实现发送原生可访问性播报，不添加未经证实的选择模态框。

快捷键快照升级为版本 3。版本 1 先执行第 690 篇备用命令合并；版本 1／2 的旧 `previous-task`／`next-task` 自定义分别保留给聊天和标签，并关闭新增最近访问默认键，保留过去“清空此命令”的效果。未自定义用户获得当前六命令默认值。升级先在内存完成，下次成功编辑再持久化；未知版本仍拒绝并保留当前有效状态。

## 验证记录

提取夹具 `task_navigation_reference_691.json` 包含六命令、11 个实际最近访问轨迹、10 个实际顺序导航边界、四种实际松开键集合、20 项上限、四个共享绑定对，另包含 10 个实际 `swa` 显式布局轨迹。`TaskNavigationReferenceTests` 23 项新增验证这些数据及主／独立窗口控制器、草稿保持、失焦取消、旧配置迁移、共享冲突、面板回退、重复按键与隐藏原生事件监视器。

- 功能红测：`.cache/task-navigation-reference-functional-red-691.log`，1 项、10 个断言失败，确认六命令和默认绑定差异。此前第一次提取缺少 `hLa` 导致无夹具的失败不计为功能红测。
- 首轮编译因两个 Coordinator 未隔离到主线程失败（`.cache/task-navigation-focused-691.log`）；修正主线程归属后 94 项通过。面板／实际选择扩大专项 125 项、原生监视器专项 127 项均通过。
- 中间专项 `.cache/task-navigation-focused-final-691.log`：128 项、0 失败／跳过，2.714 秒。隐藏窗口通过已安装的事件监视器接收 `NSApplication.sendEvent` 的 key-down／flags-changed；这证明本应用内事件路由，不证明真实系统键盘投递。
- 第一轮扩大 `.cache/task-navigation-expanded-final-691.log`：854 项、1 失败，失败是数字偏好测试仍要求全部命令绑定唯一。修正为只豁免参考四对共享规则后，使用新正式 helper 的第二轮 854 项、0 失败／跳过，244.842 秒（`.cache/task-navigation-expanded-repaired-final-691.log`），当时源码／资源／工件终态均未变；它不覆盖随后统一标签与回退修复。
- 后续实际全屏红测 `.cache/task-navigation-full-content-functional-red-691.log`：1 项、6 断言失败、0 unexpected；独立窗口标签回退红测 `.cache/task-navigation-tab-fallback-red-691.log`：1 项、2 断言失败、0 unexpected。首次全屏测试包含夹具目录错误与不等价分屏状态，日志保留但不作为上述纯功能红测。修复后中间专项中的一条物理面板假设不再适用于全屏统一顺序，已拆清分屏专项与全屏轨迹。
- 最终源码专项 `.cache/task-navigation-focused-complete-final-691.log`：**147 项、0 失败／跳过，3.051 秒**。全屏六个轨迹分别验证主／独立任务窗口；四个 primary-split 轨迹保留为参考数据，未把它们伪装成已对应 ShipiOS 的普通侧面板。
- 本轮四个 ShipiOS Rust 包 **89 项、0 失败／忽略**，`.cache/task-navigation-rust-formal-691.log`，exit 0。此前 195 项还包含 sandbox 包，不作为本轮数量。
- 最终扩大 `.cache/task-navigation-expanded-complete-final-691.log`：**857 项、0 失败／跳过，245.675 秒**，原句柄 78691 terminal exit 0；与专项重叠，不累加。运行前捕获 1,475 个来源路径、182 个编译资源及四个工件（测试执行文件、保存的最终正式 helper、参考 CSS、过滤清单），终态全部未变，见 `.cache/task-navigation-expanded-complete-{manifest,status}-691.json`。本轮使用 `.cache/verified-agent-691-final/shipios-agent`，与最终正式包 helper 字节一致；native-ui-648 至此释放。
- 最终正式包经 `script/build_and_run.sh --app` 构建与执行启动命令，exit 0（`.cache/task-navigation-build-run-final-691.log`，Swift 11.32 秒）。应用和 helper 都使用 Apple Development，指定要求与第 690 篇重建前相同，分别通过旧要求验证及严格深度校验（`.cache/task-navigation-signature-complete-final-691.log`）。本轮重新链接后的 helper 代码摘要与冻结第 688 篇不同，签名校验器起初错误地断言必须字节一致；已取消这个错误假设，报告仍保留 `helperMatchesFrozen688: false`，不把签名身份稳定当作代码字节等价。
- 最终正式 helper 的 IPC 与 Core 回环 Responses 冒烟均 exit 0／PASS（`.cache/task-navigation-{ipc,core}-complete-final-691.log`），覆盖实际事件、取消／恢复、审批、问题、工具写入和凭证清理；不调用用户 API。最终 CUA 仍返回 Mac 锁屏，不能确认工作区可交互，不计为前台启动验收。

## 尚未完成的边界

本阶段不证明快捷键整页或所有导航完全对齐。完整注册表的命令范围、排序、说明和可用条件仍需核对；序列绑定的录制、冲突、搜索和执行仍未完成。本次全屏轨迹启用了聊天标签；未启用聊天标签、持久全屏下选择聊天等状态仍待映射。`Bsc`／`swa` 的全屏／分屏、主次交换、底部面板、旧浏览器回退、空标签和焦点返回全部组合，侧栏分组／折叠／隐藏条件，以及真实 OS 按键、读屏播报与双端前台需要继续验证。分离内容窗口不接管主窗口最近访问；参考对这些窗口的完整行为仍未验收。

Mac 本轮仍锁屏。47 个页面入口和 29 项核心功能的原始范围保持不变，完整双端配对依旧 **0/47**；测试数量不能换算成页面完成比例。
