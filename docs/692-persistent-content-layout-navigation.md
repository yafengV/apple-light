# 选回聊天后的内容布局与导航

日期：2026-10-09。接续第 691 篇，核对聊天选择与内容布局是否可以共用同一状态。本阶段不表示完整全屏／分屏布局、快捷键页面或双端交互验收完成。

## 参考行为

当前公开 `app-initial-f9b16fbf8fc7.js`（26.930.51102、build 13100，SHA-256 `22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3`）的 `SHn` 将选择改为聊天；普通聊天主表面下调用 `iVn`／`aC` 隐藏内容，但不会重写 `tS` 保存的 full／split 模式。`swa` 在持久 full、当前聊天、包含聊天标签时，向前选择首个内容标签，向后选择最后内容标签；没有内容时返回未处理。

`script/extract_content_layout_navigation.cjs` 校验源哈希后执行实际 `SHn`／`iVn`／`aC` 与 `swa`，使用显式状态、空分析事件与空 UI 钩子，不初始化参考应用、不访问原生桥接、账户或用户数据。新增夹具包含四个聊天转换与六个实际选择结果。首次夹具提取因测试用 tab 缺少 `tabType` 失败，补齐占位字段后提取通过；不把此失败描述为应用功能失败。

## 本阶段范围

ShipiOS 先前从主内容选择是否为空推断 full／split。用户从完整内容选回聊天后，主选择变空，接下来 Ctrl+Tab 可能切入最近聊天流程；独立任务窗口与重启恢复有相同状态缺失。

本阶段将导航布局模式独立于当前标签选择，并保存到各任务／窗口的布局元数据。旧布局缺少新字段时仍能读取，按已有主内容选择推断初始模式；新任务／所有者切换隔离该状态。当前主表面内容布局、工作区 home、未显示聊天标签、全部主次交换／焦点组合仍需继续映射，不将原有物理面板布局推断当作参考全部模式。

独立任务窗口的 `revealChat` 与点击聊天共用选择入口，移除此前额外的“移到右侧”操作。模型选择器、会话查找、审查／PR 返回输入框因此保留内容模式与原位置。显式将主内容移到右侧仍转为 split；关闭最后内容标签后不再占用聊天导航键。

| 已验证状态 | 按键与恢复结果 |
| --- | --- |
| full，当前为聊天，有内容 | Ctrl+Tab 交给内容导航；前进首项、后退末项，继续循环保留模式 |
| split，当前为聊天 | 共享按键回到最近聊天流程 |
| 同一任务重新显示／重启恢复 | 新布局字段保留 full＋聊天；不主动抢键盘焦点 |
| 换任务／新草稿 | 不继承上一任务模式，独立窗口各任务分别持有 |
| 旧布局没有模式字段 | 有有效主内容选择推断 full，否则 split；无法恢复旧数据未保存的历史模式 |
| 没有剩余内容 | 内容切换返回未处理，不因保留 full 就抢走最近聊天按键 |

## 验证记录

- `.cache/content-layout-functional-red-repaired-fixture-692.log`：**4 项、10 个失败断言、0 unexpected**，证实聊天后完整列表、共享键和两个窗口恢复的差异。首轮 4 项、11 断言失败还含冷启动夹具过早恢复的初始化错误，保留 `.cache/content-layout-functional-red-692.log`，不将它全部归因于功能缺陷。
- 第一轮修复专项 **97 项、0 失败／跳过**；扩大新数据／迁移／隔离／原生路由专项 **101 项、0 失败／跳过**，分别见 `.cache/content-layout-focused-692.log`、`.cache/content-layout-focused-complete-692.log`。
- 程序触发的聊天显示入口红测 **1 项、6 个失败断言、0 unexpected**，`.cache/content-layout-programmatic-red-692.log`；该入口仍移动内容导致 split，已移除额外移动。
- 最终专项 **124 项、0 失败／跳过，12.757 秒**（`.cache/content-layout-focused-final-692.log`），包含新增 `ContentLayoutNavigationTests` **9 项**及导航、内容标签、恢复、窗口命令和 PR 检查附件回归。原生事件验证使用已安装的窗口监视器与隐藏窗口内 `NSApplication.sendEvent`，不等同真实 OS 按键或前台验收。
- 标准 `script/build_and_run.sh --app` 构建和执行启动命令 exit 0（`.cache/content-layout-build-run-final-692.log`，Swift 54.74 秒）。应用代码摘要改变，helper 代码摘要不变；两者 Apple Development 身份与指定要求不变，均通过旧要求及严格深度校验（`.cache/content-layout-signature-final-692.log`）。
- 保存的新正式 helper 运行 IPC 与 Core 回环 Responses 冒烟均 exit 0／PASS（`.cache/content-layout-{ipc,core}-final-692.log`），验证真实 IPC、事件、取消／恢复、审批／问题／steering、工作区写入与凭证清理，不调用用户 API。保存副本为 `.cache/verified-agent-692-final/shipios-agent`。
- 最终扩大回归 **942 项、0 失败／跳过，252.523 秒**（`.cache/content-layout-expanded-final-692.log`），原句柄 5705 terminal exit 0。与 124 项专项重叠，不累加。清单捕获 2,343 个源码路径（包含 vendor）、183 个编译资源和四个工件；终态全部摘要未变（`.cache/content-layout-expanded-final-{manifest,status}-692.json`）。native-ui-654 已释放。本轮未修改 Rust／vendor，不重复计入上一阶段 89 项 Rust。

上一阶段提交 `e06fcf3` 已启动独立全量回归：冻结 native-ui-648、测试副本 helper、89 个来源夹具及 182 个编译资源，捕获 2,344 个来源路径（本次包含 vendor）。本阶段使用 native-ui-654；全量的通过结论必须等待原句柄终态，不用于证明本阶段新增源码。

本阶段结束前原句柄 6721 再次返回运行中。原来源夹具、编译资源、执行文件／helper／CSS 摘要均未变；八个原应用源码路径已由本阶段修改，不能声称全源码未变（`.cache/content-layout-frozen-integrity-692.json`）。继续保护 native-ui-648 与其保存工件直至实际终态，后续开发可使用已释放的 native-ui-654。

## 剩余范围

布局模式与选中标签的区分只是导航状态的一部分。普通分屏、内容主表面与 workspace home 的主／辅助列表、聊天标签隐藏、全屏视觉排列、双击／菜单模式切换、全部数字导航与 RTL、焦点返回，以及真实 OS 键盘和 Codex／ShipiOS 前台配对仍需验证。

47 个页面入口、29 项核心功能保持原范围；完整双端配对仍为 0/47。测试数量不能折算为页面完成比例。

新包构建启动后 CUA 再次明确返回 Mac 锁屏。工作区可交互、真实按键与两端页面未取得本轮前台证据，不将启动命令成功、隐藏窗口或本机回环模型结果当作前台验收。
