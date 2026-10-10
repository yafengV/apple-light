# 空聊天分支与实际窗口验收

2026-10-10。本阶段补 R4 的空历史分支，并在用户确认 Mac 已解锁后推进 R7／R8 实际交互验收。实现、自动验证和实际应用证据分别记录；没有完成全部核心对齐。

## 行为与实现

空聊天及第一轮仍在执行的聊天允许从首轮之前创建分支，子聊天不包含进行中的输入、队列或伪造的已完成回合。显式选择进行中的回合或缺失历史仍拒绝。复制标题、模型选择和权限快照，来源输入保持独立。

`ConversationForkOrigin.runID` 和 `CodexForkOrigin.throughTurnID` 支持空边界；原有非空记录继续解码。原生请求显式传 `throughTurnId: null`，表示固定在首轮之前，不随来源后续输入推进。点击空分支的来源按钮保留来源任务选择，不用空回合 ID 清除选择。

Core 通过空的 resumed history 创建具有真实 lineage 的独立子线程。普通原生线程及初始分支在 start 确认前 materialize／flush rollout，失败时关闭线程再报错；文本工具会话保持原行为。私有目录、来源身份、历史文件和创建检查点校验仍保留。

此前空源线程只记录预期 rollout 路径，首轮前文件未落盘，实际分支报 `saved Codex rollout is missing`。本次修复先落盘，再确认 start；没有放宽所有权或路径校验。

## 参考依据

新增 `script/extract_initial_conversation_fork.cjs` 校验固定 Codex 26.930.51102／build 13100 的两个公开资源 SHA，执行实际 `vya` 可用性判断及 `S5t.prepareRequest`。空／首轮进行中／已完成三种请求准备通过；host、config、placement 明确使用受控替身。它只证明前端请求准备，不证明 app-server、Core 或当前 Codex 实际窗口。输出为 `.cache/initial-conversation-fork-reference-final-735.json`。

## 自动验证

首轮关联回归 **194 项、2 条失败断言（1 个意外错误）**，输入未变：一项暴露实际空线程 rollout 缺失，另一项仍沿用“空任务不可分支”的旧断言。原日志／清单保留为 `.cache/initial-conversation-fork-baseline-735.log` 和 `…-baseline-provenance-735.json`。

修复后的证据如下，重叠范围不累加：

- 预检 **19 项、0 失败／跳过，12.468 秒**。真实 Core 测试分别在本地和新工作树创建空分支，不提交模型回合；重启后先让源会话提交，再继续子会话，验证源／子原生线程身份不变、子请求不继承后来的源输入、源草稿保留。
- 最终关联 **194 项、0 失败／跳过，467.219 秒**，包括菜单、窗口、工作树、导航、恢复和批准路由。测试期间 **1553 项**输入及实际 immutable helper 摘要未变；日志／清单为 `.cache/initial-conversation-fork-fixed-final-735.log` 和 `…-fixed-final-provenance-735.json`。
- Agent **26 项、0 失败**及 helper 构建通过，**2336 项**输入未变；后续仅修正 Swift 测试的异步解包写法，Rust 输入未改。证据为 `.cache/initial-conversation-fork-fixed-agent-{tests,build}-735.log` 和 `…-fixed-agent-provenance-735.json`。
- Core 包 **51 项、0 失败，8.81 秒**，含权限隔离、会话恢复及子任务中断／关闭，**824 项**输入未变；证据为 `.cache/initial-conversation-fork-core-{tests-735.log,provenance-735.json}`。

两个此前排除的前台方法在本轮单独启用运行，仍为 **2 项、5 条失败断言（1 个意外错误），17.151 秒**：重命名夹具未获得关键窗口及 field editor；准备页夹具出现 `InvalidTransition … failed(deinit)`。输入未变，保留 `.cache/initial-conversation-fork-foreground-735.log` 和对应清单。不能把下面的实际应用成功改写成这两个自动方法已通过；最终 194 项明确排除它们。

## 构建与实际应用

标准 `script/build_and_run.sh --build-app` 通过，Swift 构建 **8.47 秒**；应用及 helper 的 Apple Development 指定要求保持第 713 篇基线，旧要求、严格深度签名和包内 IPC 通过，**1752 项**打包输入未变。证据为 `.cache/initial-conversation-fork-fixed-*-locale-final-735.*`。

实际输入通过 `cua_repl` 操作 ShipiOS，使用返回的 AX 状态、选中文本、焦点和截图检查结果。没有本轮当前 Codex 窗口配对；参考仍为冻结公开资源。

重建前的第 734 篇应用包实际确认了：设置在 `main` 内打开、搜索初始焦点、搜索跳转、Esc 清搜索／返回、旧命令名称搜索、通知／Agent／Git／环境／工作树页面切换、草稿保留及返回输入焦点。浏览器原位中文粘贴后失焦保存；固定项重命名同窗口弹层初始全选，Tab 按取消／保存／关闭移动，反向 Tab、Esc 取消和 Enter 保存正确。审查能显示真实未暂存差异及已暂存空状态，缺少 gh 的 PR 操作禁用并解释；终端 `pwd` 显示实际项目路径，快捷键隐藏后恢复聊天输入焦点。临时浏览器、固定项和草稿已清理。包 SHA 和观察范围见 `.cache/interactive-window-observation-735.json`，不能用旧包观察替代本阶段所有行为。

最新构建经标准脚本 `--app --data-root …` 启动隔离 Git 夹具。首次恢复 loading 随后消失，来源聊天与输入可交互；夹具未配置 API，源聊天没有原生线程：

1. 空来源菜单提供本地／新工作树分支。
2. 新工作树准备页在 `main` 显示初始化阶段、实际路径、返回及取消；点击取消后显示已取消及继续创建。
3. 解除受控初始化脚本等待后点击继续，复用同一目录、完成初始化并打开空子聊天。保存数据只有一个工作树，ready／setupCompleted 为真，待创建标记已清。
4. 点击“分叉自”返回空来源，仍选中正确任务并保留 `preserve fixture draft`。
5. 本地分支菜单另建空子聊天，同窗口打开，来源草稿不被复制或清除。最终三个任务均无回合。

实际路径／包 SHA／保存数据及观察记录为 `.cache/interactive-worktree-735/after-cancel-retry-evidence.json`，启动日志为 `.cache/interactive-worktree-launch-735.log`。该夹具验证真实 Git 和应用交互，不能作为真实模型服务闭环；原生 Core 空边界由上述受控模型测试独立验证。

随后通过标准脚本恢复默认用户实例，实际确认 apple-light 工作区可交互；再次 Cmd+, 在 `main` 打开设置，Esc 返回并恢复输入焦点。没有持续恢复 loading，也没有本轮新签名信任提示。启动日志为 `.cache/interactive-default-launch-735.log`。

## 剩余范围

R4 空历史、本地／新工作树准备取消重试及来源返回已有本轮实现和局部实际证据；冷窗口恢复、多窗口、错误及其他核心状态仍要逐项验收。R7／R8 的上述路径已有局部实际证据，不代表整组完成。两个前台自动夹具仍需修复或以可重复的真实应用验收替代其覆盖。

用户独立 API 尚未保存，应用仍显示“配置模型…”。R1／R2／R6 的真实服务开发闭环继续等待用户在设置填写已有服务，不索取聊天中的密钥。固定第 732 篇 3453 项广泛回归的成功不包含本篇源码；当前 194 项也不称为最新全量通过。保持 R1—R8 交付范围。
