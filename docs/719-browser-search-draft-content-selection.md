# 浏览器搜索返回草稿时直接选择目标内容

日期：2026-10-09。处理固定第 717 篇完整回归发现的真实浏览器搜索失败，接续第 715 篇空白页清理和第 718 篇完整视图规则。完整目标仍为 47 个页面、29 项核心功能，完整双端配对保持 **0/47**。

## 问题与修复

`CommandBrowserSearchTests.testBrowserResultOpensOwnerAndPaneWithoutChangingDraftsAndRejectsClosedOrDetachedTabs` 在未发送草稿中的完整视图空白页返回路径产生两条失败断言。搜索结果原本仍有效，切换到该草稿后，`applyWorkspaceDraftSelection` 无条件执行 `activateChatTab`，触发第 715 篇的唯一空白页清理，导致目标在最后激活前被关闭。这是产品路径错误，不能通过给夹具增加地址草稿来绕过。

参考第 715／718 篇固定版本的 `QJ`：选择聊天会检查空白页丢弃，选择内容走内容激活。此次让草稿选择接口显式接收待显示的内容 ID；搜索从其他任务返回草稿时直接选择该目标，不经过临时聊天选择。没有修改空白页可丢弃条件，也没有停用主动选回聊天的清理规则。

| 路径／状态 | 当前行为 |
| --- | --- |
| 搜索返回普通未发送草稿 | 直接选择原网页，保留实例、草稿文字和 full／split 布局 |
| 搜索返回带 nonce 的关联草稿 | 保留精确草稿身份，普通草稿与其他任务输入不变 |
| 地址未输入、输入后清空或仍有输入 | 均能通过搜索返回原实例，不提交地址内容 |
| 目标缺失／已关闭／属于其他任务 | 在切换前拒绝；不生成替代标签 |
| 目标在底部／分离窗口 | 不作为主内容恢复目标，保留当前选择与历史 |
| 异步项目切换 | 切换前、scope 返回后和草稿应用前分别验证目标身份、所属草稿及可用主面板；真实 Agent 闸门期间关闭目标后不重建 |
| 跨项目成功返回与冷恢复 | 原空白 full 页面实例、选择及草稿保持；重启后恢复原内容 ID 和 full 布局 |
| 普通新任务／历史／返回聊天 | 未传入内容目标时沿用原有聊天选择，包括唯一可丢弃空白页清理 |

这些是当前实现和测试范围。没有执行 Codex 前台搜索界面，不把内容选择函数的参考结果等同于完整搜索弹层／跨项目路由配对。

## 验证

在修改产品代码前，原用例加上新搜索生命周期用例共执行 **4 项，2 个失败方法／7 条失败断言**（`.cache/command-browser-draft-red-719.log`），明确复现空白 full 目标被关闭；split 和已输入／清空的草稿分别作为保护条件比较。

首轮专项 **6 项、0 失败／跳过**（`.cache/command-browser-draft-focused-final-719.log`），包含原失败用例、full／split 各三种地址状态、精确关联草稿身份、失效／其他归属／底部／分离目标拒绝以及搜索匹配和分组键盘规则。循环场景不是独立 XCTest 方法。

首轮扩大 **204 项通过**（`.cache/command-browser-draft-expanded-719.log`）；筛选检查发现还包含一个实际隐藏窗口的关联草稿冷恢复方法，故最终筛选补排除该方法，不把首轮视为全部没有窗口操作。补排除窗口后的扩大 **203 项、0 失败／跳过**，6.871 秒，exit 0（`.cache/command-browser-draft-expanded-final-719.log`）。范围包含布局、空白页清理、浏览器本地 WebKit、快捷键、固定项恢复并发、关联草稿和搜索；原生窗口方法明确排除，避免继续干扰固定版本完整回归。源码、测试程序和资源输入全部未变，清单／筛选范围见 `.cache/command-browser-draft-expanded-final-provenance-719.json`。

补充真实 Agent 跨项目与冷恢复测试：首次 8 项中，跨项目成功方法的两条目录 URL 比较断言因尾部斜杠不同而失败（`.cache/command-browser-draft-scope-719.log`），内容／布局和闸门期间目标关闭断言通过。改为比较实际目录路径后，最终专项 **8 项、0 失败／跳过**（`.cache/command-browser-draft-scope-final-719.log`）。最终扩大 **205 项、0 失败／跳过**，7.985 秒，exit 0（`.cache/command-browser-draft-expanded-scope-final-719.log`）；全部冻结输入未变，清单见 `.cache/command-browser-draft-expanded-scope-final-provenance-719.json`。没有调用真实模型 API。

标准 `script/build_and_run.sh --build-app` 正式构建／打包 exit 0（`.cache/command-browser-draft-build-run-final-719.log`）。主应用和 helper 使用 Apple Development，指定要求保持第 713 篇基线，旧要求及严格深度校验通过（`.cache/command-browser-draft-signature-final-719.json`）；构建前后 **1,618 项冻结输入未变化**（`.cache/command-browser-draft-package-final-provenance-719.json`）；包内 Agent IPC 冒烟 exit 0（`.cache/command-browser-draft-ipc-final-719.log`）。仅构建，未启动新应用，不计为前台工作区验收。

## 完整回归与剩余范围

固定 `57f924f` 的完整回归继续在独立检出／缓存运行，未改动冻结源码，也未因本次失败重启原进程。原失败留在该固定版本日志中，本次专项通过不能将其覆盖为全量通过。修复后的完整全量仍待原进程终态后安排。

本轮不重启正式应用，没有完成搜索弹层的真实鼠标／OS 键盘、跨项目实际页面返回、两种窗口的前台焦点和 Codex 双端配对。其他失效路径的历史回滚、primary workspace、全部搜索类型／排序，以及原矩阵其余页面与核心功能仍待完成。
