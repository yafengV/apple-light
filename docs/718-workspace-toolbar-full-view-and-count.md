# 工作区工具栏完整视图与数量状态

日期：2026-10-09。接续第 717 篇，主窗口和任务窗口使用同一套工具栏状态，修正完整视图选回聊天后的错误切换。原 47 个页面、29 个核心功能的验收范围不变，完整双端配对仍为 **0/47**。

## 参考依据

固定 Codex 26.930.51102／build 13100。`script/extract_workspace_full_view.cjs` 校验 initial、chrome、shared JS 和 CSS 的 SHA-256，在隔离 VM 中执行普通工作区实际 `pwa` 布局转换、`eu`／`Ql` 工具栏组件和 `jfs` 数量组件。夹具 `workspace_full_view_reference_718.json` 包含 12 条转换、15 组工具栏状态、5 组数量结果。完整视图隐藏后的初始状态显式设置 `nS`，避免仅把保存的 full 模式当作可见完整视图。

提取没有加载参考应用，没有绕过此前拒绝的 Codex 桌面访问。替代范围为 atoms、JSX、原生副作用和焦点投递；结果证明这些组件和布局函数的逻辑，不证明真实 DOM／OS 焦点、primary workspace、cloud 或逐页前台配对。图标采用独立 AppKit 几何绘制，没有复制参考 SVG。

## 具体对齐内容

| 状态／操作 | 本次实现 |
| --- | --- |
| full 内容实际可见 | 显示“退出完整视图”，完整按钮按下，点击切回 split |
| 保存 full 但当前选回聊天 | 显示“进入完整视图”，完整按钮未按下，点击打开保留内容的 full 视图 |
| split 内容可见或内容隐藏 | 完整按钮进入 full，保留原内容身份和窗口归属 |
| 没有主内容标签 | 完整按钮创建完整视图的新浏览器标签 |
| 主布局按钮，内容可见 | 分栏图标；只有实际 split 显示按下状态 |
| 主布局按钮，内容隐藏 | 矩形内显示数量；空集合显示加号；1—9 使用 8px 数字，超过 9 显示 6px 的 `9+` |
| 原“任务布局”菜单 | 两窗口改为直接完整视图按钮；标签栏显隐和交换面板仍由已有应用菜单／快捷键提供 |
| 完整视图目标选择 | 主窗口过滤底部终端、分离窗口与其他任务内容；任务窗口沿用主内容过滤；设置页／搜索弹层不能直接触发主窗口布局命令 |
| 指针／键盘／辅助操作 | 沿用原生按钮的 Tab、Return／Space、禁用／窗口模态和拆除保护；增加当前状态的辅助值、主题选中背景和焦点边框 |

## 验证与失败记录

新参考转换测试在修复前执行 2 个方法，4 条断言失败：主／任务窗口隐藏 full 内容后均错误变成 split（`.cache/workspace-full-view-red-718.log`）。测试前后源码／测试快照一致。

实现后参考转换和工具栏状态通过，新增底部终端测试首次失败：夹具只有任务项目路径，没有设置实际工作区项目，终端没有创建。补齐夹具实际目录后，最终专项 **5 项、0 失败／跳过**（`.cache/workspace-full-view-focused-final-718.log`），包含 12 条转换分别在两种窗口核对，以及工具栏状态、数量阈值和面板范围保护。修正了第 694 篇旧测试中“按保存模式切换”的断言，改按本次实际参考显示状态。

扩大相关回归 **186 项、0 失败／跳过**，5.144 秒，exit 0（`.cache/workspace-full-view-expanded-718.log`）。`.cache/workspace-full-view-expanded-provenance-718.json` 保留过滤范围、排除方法、源码／资源／测试程序快照，全部未变化。为了保护正在运行的独立完整回归，本轮排除了 7 个既有窗口挂载／按键方法及第 717 篇 6 个 native 窗口方法；这不是这些窗口行为在本轮通过的证据。参考提取脚本再次生成后与提交夹具逐字节一致。

标准 `script/build_and_run.sh --build-app` 正式构建／打包 exit 0（`.cache/workspace-full-view-build-run-final-718.log`）；主应用和 helper 使用 Apple Development，指定要求与第 713 篇基线一致，旧要求及严格深度校验通过（`.cache/workspace-full-view-signature-final-718.json`）。构建前后 **1,617 项冻结输入未变化**（`.cache/workspace-full-view-package-final-provenance-718.json`）；包内 Agent IPC 冒烟 exit 0（`.cache/workspace-full-view-ipc-final-718.log`）。仅打包，未启动新应用，不能算前台验收。

## 完整回归与待验收

固定 `57f924f` 的独立完整回归已通过全部测试编译和前置组，仍执行 `swift-full`；已通过进程检查确认原 supervisor 与 swift-test 存活，没有重启、覆盖其缓存或修改冻结检出。当前日志已出现 `CommandBrowserSearchTests.testBrowserResultOpensOwnerAndPaneWithoutChangingDraftsAndRejectsClosedOrDetachedTabs` 的失败，保留原结果并待排查，不计为全量通过。该固定版本不包含本次修复。

本轮尚未重启新包或进行前台窗口操作。仍需完整按钮的真实鼠标、键盘和两种窗口焦点验收、图标／数量／选中背景的实际尺寸和像素对照、primary workspace／单聊天特殊路由及 browser capability 可用性条件、所有页面和全部核心功能的双端验收。本篇不能视为工具栏或整个 UI 已完全对齐。
