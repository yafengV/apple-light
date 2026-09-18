# Codex 与 ShipiOS：逐页交互差异审计

> 最新逐页汇总见 [当前页面与交互验收清单](37-current-page-status.md)，新增分支交互见 [Git 分支选择与主窗口导航](36-git-branch-selection.md)。下文保留初次审计现场，不代表后续功能仍全部缺失。

审计日期：2026-09-16。结论：**尚未完全对齐，当前只具备部分相似的工作区结构与本地任务组织。** 上一轮测试通过证明 ShipiOS 已实现的功能可以工作，不能证明与 Codex 等价。

> 本页保留审计时的基线。后续修复与验证见 [桌面补齐与 API 配置](12-desktop-parity-progress.md)、[主窗口内导航](13-in-window-navigation.md)、[设置与键盘交互](14-settings-and-keyboard-interactions.md)、[多项目侧栏与项目菜单](15-project-sidebar-interactions.md)、[分组与排序](16-sidebar-groups-and-ordering.md)、[面板尺寸控制](17-resizable-workspace-panels.md)、[Git 审查范围](18-git-review-scopes.md)、[逐文件差异与行内反馈](19-inline-review-feedback.md)、[编辑器定位与重命名文件](20-editor-navigation-and-renames.md)、[审查页分块操作](21-review-hunk-actions.md)、[批量暂存与取消暂存](22-batch-staging.md)、[原生审查与撤销验收](23-native-review-validation.md)、[会话 Markdown 与复制交互](24-conversation-markdown.md)、[外观设置与返回验收](25-appearance-and-settings-validation.md)、[会话滚动与查找](26-conversation-scrolling.md)、[逐处查找与高亮](27-conversation-find-occurrences.md)、[输入区模型与推理强度选择](28-composer-model-selection.md)、[会话分叉与历史边界](29-conversation-forking.md)、[主窗口内个性化设置](30-personalization-settings.md)、[通知设置与任务跳转](31-notification-settings.md)、[运行时防止休眠](32-prevent-idle-sleep.md)、[主窗口设置与全局命令交互](33-main-window-command-routing.md)、[无项目新任务与会话恢复](34-projectless-conversations.md)、[图片附件与会话上下文](35-image-attachments.md)。仍未达到完全对齐。

## 证据范围

- Codex：本轮实际获取的 OpenAI 官方文档，采用 desktop/app 段落，排除 CLI、IDE、网页专属行为。文档当前使用“ChatGPT desktop app 中的 Codex”等称呼，不据此推断用户安装版本的外观。
- ShipiOS：当前源代码、本轮原生窗口实际检查、[上一轮真实执行验收](10-desktop-interactions.md)。本轮未修改应用逻辑，也未重新运行全部构建测试。
- 限制：UI 工具禁止读取 Codex 应用自身。未获取用户当前 Codex 的完整页面、弹窗和状态截图，**未完成两个 App 逐页交替操作的实机配对验收**。字体、间距、悬停、动画、焦点顺序等不得标为一致。
- 标记：**部分**＝功能有交集但不能认定等价；**差异**＝已找到具体行为不同；**缺失**＝ShipiOS 没有对应实现；**未核验**＝缺乏当前版本的配对证据；**专属**＝ShipiOS 自己的业务功能。

下面按用户进入应用后的顺序检查。表格中的“Codex”指引用文档描述的桌面行为，不能替代用户当前版本的实测。

## 1. 启动、登录与新任务页

依据：[登录](https://learn.chatgpt.com/docs/auth)、[项目与任务](https://learn.chatgpt.com/docs/projects)、[工作树](https://learn.chatgpt.com/docs/environments/git-worktrees)。ShipiOS 证据：`ShipiOSApp`、`ConversationView`、`WorkspaceStore.restore/open`。

| 编号 | 检查项 / Codex 行为 | ShipiOS 当前行为 | 结论 |
| --- | --- | --- | --- |
| A01 | 登录页：ChatGPT 或 API Key 两种入口 | 没有登录与模型凭据界面 | 缺失 |
| A02 | 账户菜单：查看身份、退出登录 | 左下角只有本地连接状态和设置 | 缺失 |
| A03 | 可从项目开始，也可创建无项目任务 | 执行操作需要选定文件夹；无项目时发送按钮打开项目面板 | 差异 |
| A04 | 新任务可选择 Worktree 和起始分支 | 只有当前本地项目、诊断/构建及 Scheme | 缺失 |
| A05 | 首屏文案、建议项、位置、大小与焦点 | 固定欢迎文案和两项构建相关建议 | 未核验；建议内容为产品专属 |

## 2. 侧栏、项目页与任务菜单

依据：[项目组织](https://learn.chatgpt.com/docs/projects#organize-projects-and-chats)、[命令](https://learn.chatgpt.com/docs/reference/commands)。ShipiOS 证据：`TaskSidebarView`、`WorkspaceLibrary`。

| 编号 | 检查项 / Codex 行为 | ShipiOS 当前行为 | 结论 |
| --- | --- | --- | --- |
| B01 | 项目与任务组织 | 当前项目可展开任务；其他最近项目是切换按钮 | 部分；尚无多项目任务同时展开 |
| B02 | Projects 页面及项目搜索 | 没有独立项目页面或项目搜索 | 缺失 |
| B03 | 编辑项目、添加多个文件夹、设置主文件夹 | 一个项目对应一个目录，无编辑项目对话框 | 缺失 |
| B04 | 项目置顶 | 仅支持任务置顶 | 缺失 |
| B05 | 任务置顶、重命名 | 右键菜单实现；没有文档列出的对应快捷键 | 部分 |
| B06 | 归档任务及批量归档项目任务 | 只有单个任务归档；运行中禁用 | 部分；Codex 运行中归档行为未核验 |
| B07 | 从 Settings > Archived chats 恢复，显示日期和项目上下文 | 侧栏“已归档”过滤当前项目；行上没有日期/项目上下文 | 差异 |
| B08 | 标记未读、清除未读、跳到需关注任务 | 只有运行转圈和失败点，无已读/未读状态 | 缺失 |
| B09 | 自定义分组、拖动排序的具体方式 | 无分组编辑或拖动排序 | 当前 Codex 具体手势未核验；ShipiOS 缺失 |
| B10 | 返回/前进、前后任务或标签页切换 | 点击侧栏换任务，无导航历史和任务标签页 | 缺失 |

## 3. 输入区、菜单与运行中交互

依据：[提示与运行中追加](https://learn.chatgpt.com/docs/prompting#steering-and-queuing)、[斜杠命令](https://learn.chatgpt.com/docs/reference/slash-commands)、[设置](https://learn.chatgpt.com/docs/reference/settings)、[图片输入](https://learn.chatgpt.com/docs/image-inputs)。ShipiOS 证据：`ComposerView`、`LocalAction`、`WorkspaceStore.sendDraft/submit`。

| 编号 | 检查项 / Codex 行为 | ShipiOS 当前行为 | 结论 |
| --- | --- | --- | --- |
| C01 | 自然语言指令驱动 Agent | 普通文本只保存为说明，并执行已选定的诊断或构建 | 差异；是主要行为差距 |
| C02 | 模型与推理强度选择 | 下拉只有“环境诊断”和“构建项目” | 缺失；两个操作不能充当模型选择 |
| C03 | 输入 `/` 显示候选，继续输入过滤 | 本轮实测输入 `/` 无候选菜单；提交时解析两种命令 | 差异 |
| C04 | `/plan`、`/review`、`/fork`、`/status` 等 | 仅 `/doctor`、`/build`，其他命令报错 | 缺失 |
| C05 | `@` 插件及 `$` 技能等上下文入口 | 没有自动补全、选择器或上下文标签 | 缺失 |
| C06 | 文件/图片输入；桌面文档描述 Shift 拖入图片 | 纯文本输入，无附件、拖放和预览实现 | 缺失 |
| C07 | 设置多行提示的发送方式 | 固定 `⌘Enter` 执行，没有发送方式设置 | 差异；当前 Codex 的用户偏好待核验 |
| C08 | 执行中追加消息，选择 Steer 或 Queue | 执行中只显示停止；可以编辑草稿但无法追加执行 | 缺失 |
| C09 | 队列在输入区上方，可编辑、重排、发送、删除 | 没有队列 UI 或调度逻辑 | 缺失 |
| C10 | 空输入区按 ↑ 恢复上一条提示 | 没有历史输入恢复 | 缺失 |
| C11 | 语音听写入口和快捷键 | 没有听写入口 | 缺失 |
| C12 | 计划/目标模式的进度及控制 | 无模式或目标状态 | 缺失 |
| C13 | 停止、停止中反馈、取消后可继续 | 本地进程取消和记录已实现；不涉及模型流中断 | 部分；不能等同于停止 Agent 回合 |
| C14 | 草稿切换、重启、重试的保留语义 | 已验证本机草稿保留，重跑不清空草稿 | ShipiOS 已验收；Codex 配对语义未核验 |

## 4. 会话页与执行记录

依据：[提示与迭代](https://learn.chatgpt.com/docs/prompting)、[文件与任务侧栏](https://learn.chatgpt.com/docs/artifacts-viewer)、[命令](https://learn.chatgpt.com/docs/reference/commands)。ShipiOS 证据：`ConversationView/ExecutionMessageView`。

| 编号 | 检查项 / Codex 行为 | ShipiOS 当前行为 | 结论 |
| --- | --- | --- | --- |
| D01 | Agent 理解并生成响应，多轮继续工作 | 同一任务归组多次本地 Run，摘要由固定状态文案生成 | 差异 |
| D02 | 工具调用、进度、计划和最终结果的呈现 | 可折叠执行卡，只有已选 Run 的事件详情 | 部分；缺少完整 Agent 事件模型 |
| D03 | 文件、代码和可交互产物的展示 | 文本摘要、Xcode 输出、首条诊断；无完整富文本/代码块/媒体组件 | 缺失 |
| D04 | 复制、重试、编辑消息、分叉的细节 | 复制固定摘要、重跑原请求；无编辑消息或分叉 | 部分；复制/重试的 Codex 精确语义未核验 |
| D05 | 回合内审批请求，键盘批准/拒绝 | 没有审批卡片或等待用户输入状态 | 缺失 |
| D06 | 回到底部、阅读历史时新内容到达的滚动策略 | 任务变化/执行数增加时滚到末尾；没有“新消息”入口 | Codex 策略未核验；ShipiOS 需补状态设计 |
| D07 | 弹出独立任务窗口、Always on top | 没有对应任务操作；WindowGroup 共用一个 Store 不代表独立任务窗口 | 缺失 |

## 5. 命令面板、搜索与定位

依据：[官方命令与搜索](https://learn.chatgpt.com/docs/reference/commands)。ShipiOS 证据：本轮 `⌘K` 实测、`TaskSearchView`、App 菜单。

| 编号 | 检查项 / Codex 行为 | ShipiOS 当前行为 | 结论 |
| --- | --- | --- | --- |
| E01 | `⌘K` / `⌘⇧P` 打开命令菜单 | `⌘K` 打开任务搜索，`⌘⇧P` 无对应命令菜单 | 明确差异 |
| E02 | 搜索历史任务；扩展匹配可涵盖内容和分支 | 只查当前项目任务标题和用户说明，无分支或响应内容 | 部分；所有主机/项目的实际检索边界待核验 |
| E03 | `⌘F` 在当前会话定位，`⌘G` 跳下一个匹配 | 无会话内查找 | 缺失 |
| E04 | `⌘P` 查找文件 | 无文件搜索 | 缺失 |
| E05 | 搜索结果的预览、命中高亮、分组和焦点顺序 | 简单列表、方向键、回车与 Esc | Codex 具体呈现未核验 |

## 6. 文件、审查与右侧面板

依据：[代码审查](https://learn.chatgpt.com/docs/code-review?surface=app)、[文件预览](https://learn.chatgpt.com/docs/artifacts-viewer)、[浏览器](https://learn.chatgpt.com/docs/browser?surface=app)。ShipiOS 证据：本轮实际切换三个详情页、`RunInspectorView`、`WorkspaceView`。

| 编号 | 检查项 / Codex 行为 | ShipiOS 当前行为 | 结论 |
| --- | --- | --- | --- |
| F01 | 文件树、文件标签页、编辑器打开及定位 | 仅 Finder 打开项目或产物目录 | 缺失 |
| F02 | 审查视图：未暂存、已暂存、Commit、Branch、Last turn | 右侧是编译诊断/日志/产物，无 Git Diff | 缺失；详情面板不是审查面板 |
| F03 | 展开文件 Diff、定位行、添加行内评论 | 没有 Diff 组件或评论 | 缺失 |
| F04 | 整体/文件/片段级暂存、取消暂存、还原 | 没有 Git 操作 | 缺失 |
| F05 | Commit、Push、PR 流程 | 没有相关界面或后端 | 缺失 |
| F06 | 文件预览和标注 | 只显示产物路径、退出码、耗时，支持导出 JSON | 缺失 |
| F07 | 内置浏览器、导航、预览与评论 | 没有浏览器面板 | 缺失 |
| F08 | 面板宽度、标签切换、拖动、开关后的状态保持 | 右面板自动分配宽度、三个固定页；不能独立拖宽，开关状态不持久化 | Codex 精确规则未核验；已知实现有限 |
| F09 | Xcode 构建诊断与产物 | 有本地编译专用信息 | 专属；应保留，不能用来替代通用文件/审查能力 |

## 7. 终端、运行环境与工作树

依据：[终端](https://learn.chatgpt.com/docs/integrated-terminal)、[本地环境](https://learn.chatgpt.com/docs/environments/local-environment)、[工作树](https://learn.chatgpt.com/docs/environments/git-worktrees)。ShipiOS 证据：View 清单、Agent 协议与 `WorkspaceStore`。

| 编号 | 检查项 / Codex 行为 | ShipiOS 当前行为 | 结论 |
| --- | --- | --- | --- |
| G01 | 任务内终端，绑定项目或工作树，实时输入输出 | 任务结束后读取日志，不是终端 | 缺失 |
| G02 | 环境设置脚本和可配置顶部运行操作 | 只有固定 doctor/build 参数 | 缺失 |
| G03 | 新任务选择本地/工作树、起始分支 | 全部运行在所选原目录 | 缺失 |
| G04 | 多任务在独立工作树并行执行 | 当前 Store 单 Agent、一次运行一个任务；运行中不能切项目 | 缺失 |
| G05 | Handoff 在 Local 与 Worktree 间迁移任务及代码 | 没有迁移流程 | 缺失 |
| G06 | 工作树管理、清理与恢复 | 没有工作树目录、状态或设置 | 缺失 |

注意：仓库中为 **Codex 自身** 配置了 Run 动作，只用于启动 ShipiOS。它不代表 **ShipiOS 内部** 已实现环境动作管理。

## 8. 设置各页

依据：[常规设置](https://learn.chatgpt.com/docs/reference/settings)、[开发者设置](https://learn.chatgpt.com/docs/developer-settings?surface=app)、[工作树设置](https://learn.chatgpt.com/docs/environments/git-worktrees)。ShipiOS 三个设置页本轮均已实际打开。

| 编号 | Codex 设置内容 | ShipiOS 当前行为 | 结论 |
| --- | --- | --- | --- |
| H01 | General：发送方式、防休眠、追加消息行为 | “通用”只有主题和能力说明 | 差异 |
| H02 | Appearance：基础主题、颜色、UI/代码字体 | 只有系统/浅色/深色 | 部分 |
| H03 | Keyboard Shortcuts：检索、改键、恢复默认 | 只读快捷键清单 | 差异 |
| H04 | Profile：身份与活动统计 | 无 | 缺失 |
| H05 | Notifications：完成通知策略 | 无 | 缺失 |
| H06 | Personalization：响应风格、自定义指令 | 无 | 缺失 |
| H07 | Memories 与 Suggested prompts | 无记忆，首屏是固定两项建议 | 缺失 |
| H08 | Archived chats：列表与恢复 | 设置无此页，放在侧栏当前项目内 | 差异 |
| H09 | 项目/终端行为、Git、Worktrees | 无相关设置 | 缺失 |
| H10 | Integrations/MCP：连接、OAuth、状态 | 无 | 缺失 |
| H11 | Browser、Computer Use、Pets | 无 | 缺失 |
| H12 | 运行时/模型 | 只读本地连接和路径，模型提示“尚未连接” | 缺失模型配置；路径展示是已有功能 |

官方页面对 Review delivery 的设置路径存在不一致：Code review 页面写 General > Code review，Developer settings 写 Git > Review delivery。**路径列为版本待核验，不任选一处冒充实测。** 具体设置侧栏名称、顺序及权限依赖同样需用户当前版本佐证。

## 9. 扩展页面与跨设备能力

依据：[定时任务](https://learn.chatgpt.com/docs/automations)、[插件](https://learn.chatgpt.com/docs/plugins)、[功能目录](https://learn.chatgpt.com/docs/features)、[深链接](https://learn.chatgpt.com/docs/reference/commands#deep-links)。

| 编号 | Codex 页面/流程 | ShipiOS 当前行为 | 结论 |
| --- | --- | --- | --- |
| I01 | Scheduled 列表、创建/管理、运行记录 | 无计划任务页面或调度器 | 缺失 |
| I02 | Plugins 目录、详情、已安装与连接流程 | 无插件页面或管理器 | 缺失 |
| I03 | Skills 与相关调用入口 | 无技能页面或加载器 | 缺失 |
| I04 | Connections / Remote / SSH 相关设置与操作 | 仅本地子进程 | 缺失 |
| I05 | 任务、设置、插件等深链接 | 无产品 URL 路由 | 缺失 |
| I06 | 分享、通知弹窗、升级提示等当前版本细节 | 未实现对应产品流程 | Codex 页面库存尚未实机穷举 |

这部分描述差距，不表示都应立即纳入 ShipiOS 第一版。保留配置独立性仍是已确认的产品要求；交互参考不意味着读取用户个人 Codex 的账户、配置或任务库。

## 10. 快捷键逐项对照

依据：[macOS 官方默认快捷键](https://learn.chatgpt.com/docs/reference/commands#keyboard-shortcuts)。用户可改键，当前安装版本的实际绑定仍待核验。

| 编号 | 行为 | Codex 文档默认 | ShipiOS | 结论 |
| --- | --- | --- | --- | --- |
| K01 | 新任务 | ⌘N 或 ⌘⇧O | ⌘N | 主绑定相同，备用缺失 |
| K02 | 打开文件夹 | ⌘O | ⌘O | 主绑定相同 |
| K03 | 切换侧栏 | ⌘B | ⌘B | 主绑定相同 |
| K04 | 设置 | ⌘, | ⌘, | 主绑定相同 |
| K05 | 命令菜单 | ⌘K 或 ⌘⇧P | 无；⌘K 被用作任务搜索 | 差异 |
| K06 | 任务搜索 | 默认未绑定，可自行配置 | 固定 ⌘K | 差异 |
| K07 | 归档 / 置顶 / 重命名 | ⌘⇧A / ⌘⌥P / ⌘⌥R | 无 | 缺失 |
| K08 | 会话内查找 | ⌘F | 无 | 缺失 |
| K09 | 快捷键设置 | ⌘/ | 无 | 缺失 |
| K10 | 文件搜索 / 文件树 | ⌘P / ⌘⇧E | 无 | 缺失 |
| K11 | 终端 / 底部面板 | Ctrl+反引号 / ⌘J | 无 | 缺失 |
| K12 | 审查面板 | ⌘⌥B | ⌘⇧I 打开的是执行详情 | 功能和键位均不等价 |
| K13 | 运行环境主动作 | ⌘⇧D | ⌘⇧B 固定构建 | 差异 |
| K14 | 浏览器面板 | ⌘⇧B | 同组合被用作构建 | 差异 |
| K15 | 空输入恢复上条提示 | ↑ | 无 | 缺失 |

## 11. 视觉与边界状态：尚未配对的验收项

| 编号 | 必须用相同窗口条件比对的内容 | 当前状态 |
| --- | --- | --- |
| V01 | 标题栏高度、侧栏宽度、字体、行高、留白、图标、圆角、分割线与材质 | ShipiOS 有独立实现，没有 Codex 配对截图 |
| V02 | 新建/已有/长会话，空列表/搜索无结果/错误/断连状态 | ShipiOS 部分已测，Codex 配对未核验 |
| V03 | 悬停菜单、右键、单击/双击、拖放、滚动和选中文字 | 尚无逐手势等价验收 |
| V04 | Tab/Shift-Tab、Esc、焦点恢复、中文输入法组合输入与发送 | 仅覆盖部分快捷键，未做完整输入法/焦点矩阵 |
| V05 | 大小窗口、显示缩放、浅/深色、面板开合、窗口恢复 | ShipiOS 做过窄窗口和主题检查，不能推断像素一致 |
| V06 | 长任务状态更新、网络错误、审批、模型流、退出恢复 | 仅本地执行状态已测；模型相关状态尚不存在 |

## 本轮实际操作记录

1. 打开 ShipiOS 新任务页，读取侧栏、输入区、工具栏和空详情面板。
2. 按 ⌘K，确认是“搜索当前项目的任务”弹窗，非命令菜单；Esc 关闭。
3. 打开设置，依次检查快捷键、通用、运行时三个页；未修改设置值。
4. 在空草稿输入 `/`，确认没有候选；恢复为空，展开模式菜单，确认只有诊断/构建。
5. 打开既有“桌面交互验收”任务，展开执行卡，依次查看诊断、日志、产物。
6. 源码检查所有 View、App 菜单与 Store，确认未实现的页面和状态，不依靠“没在当前屏幕看到”推断功能缺失。

历史中的构建成功、停止、归档恢复、草稿持久化测试沿用上一轮证据，本轮没有将其冒充重新执行的测试，也没有给 Codex 本地实机打通过标记。

## 补齐顺序与完成标准

1. **先修正基础交互差异**：命令菜单与搜索分离、快捷键、归档设置入口、项目/任务组织、输入补全、面板导航。以 E01、B07、K05–K09、C03 为第一批验收编号。
2. **建立真实会话能力**：模型/推理选择、文本响应、工具事件、审批、Steer/Queue、附件。需要实际 Runtime 支持，不能靠静态按钮或模板响应认定完成。
3. **补工作区开发能力**：文件树、文件预览、终端、Diff/评论、Git、工作树及环境动作。
4. **核对设置与扩展页**：根据产品范围纳入插件、定时任务、远程连接等；明确不做的项保留差异记录。
5. **逐状态视觉回归**：固定版本、窗口尺寸、缩放和主题，对两个 App 的相同输入执行相同步骤。

每个编号的最终验收都应有：Codex 版本、前置状态、操作序列、Codex 结果证据、ShipiOS 结果证据、差异、修复位置、回归结果。只有两侧结果可核对才可改成“一致”。

要继续完成用户当前版本的实机对照，需要用户提供 Codex 页面截图或操作录屏。建议录制顺序：主界面与侧栏 → 新任务输入区各菜单 → 任务运行和追加消息 → 搜索/命令面板 → 文件/终端/审查 → 设置各页 → 插件/定时任务。静态截图只能验证外观，交互需要录屏或操作说明。该材料补齐前，本报告是有证据的差异审计，不是完整对齐验收。
