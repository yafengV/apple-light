# ShipiOS

ShipiOS（暂定名）是一款面向已有 iOS 项目的 AI 开发与交付工具：复用成熟 Coding Agent，连接代码修改、Xcode 构建、Simulator 验证、TestFlight 和 App Store 发布准备。

当前阶段：**原生 macOS 工作台已实现**。SwiftUI 客户端连接独立 Rust Agent，支持本地诊断与构建、任务组织、项目内及无项目的独立 API 文字/图片/文件会话、按任务并行模型回合、持久目标模式、运行中引导与消息队列、命令面板、文件预览、Git 审查、PTY 终端和内置浏览器。Codex Core 已通过独立的 Responses RPC 通道接入 Rust Agent；Swift 设置可显式选择 Responses，已连接项目中的文字、图片和文本/PDF 附件会话可使用这条通道并在应用重启后继续原线程。原生计划模式、写入审批、MCP 工具与手动上下文整理已有自动化验证；完整 Codex 交互对齐仍未完成。目录名 `apple-light` 暂时保留；产品名、许可证与公开仓库名尚未定案。

固定上游版本的 `codex-core-api` 已完成配置隔离、本地假服务回合、Agent RPC、Swift 文字/图片/文本文件会话与重启续接验证，见[最新验证记录](docs/194-codex-file-input.md)。

文档依据：[赚钱项目建议](chatgpt-conversation://6aaa387e-5e60-83ee-a9bb-31cbc449ec8f) 的全部 7 轮对话。整理与有限技术核对日期：2026-09-16。

## 本地运行

需要 macOS 14+、Swift 6.2+、Rust 1.95+；构建 iOS fixture 需要完整 Xcode 与 iOS Simulator SDK。已在 Rust 1.97.1、Xcode 26.3 上验证。首次构建需要下载依赖；无需 API Key。Markdown 解析依赖要求 Swift 6.2 工具链，应用仍支持 macOS 14。

```bash
# 构建并启动原生 macOS 应用（也可点击 Codex 的 Run 按钮）
./script/build_and_run.sh

# 仅打包到 dist/ShipiOS.app
./script/build_and_run.sh --build-app

# CLI 环境诊断
./script/build_and_run.sh doctor

# 构建随仓库附带的最小 iOS App
./script/build_and_run.sh --project fixtures/HelloShipiOS build \
  --container HelloShipiOS.xcodeproj --scheme HelloShipiOS

# 查看有效配置、项目与历史任务
./script/build_and_run.sh config
./script/build_and_run.sh inspect
./script/build_and_run.sh runs

# 测试与原生客户端通信验证
./script/test.sh
python3 script/smoke_ipc.py
./script/verify_swift_ipc.sh
```

桌面应用默认将数据存入 `~/Library/Application Support/ShipiOS/Desktop/Projects/<项目路径哈希>/`，每个项目独立保存；可通过 `./script/build_and_run.sh --app --data-root "$PWD/.shipios-local/desktop"` 选择开发数据目录。CLI 脚本数据存入忽略的 `.shipios-local/`。直接启动 Agent 默认使用 `~/Library/Application Support/ShipiOS`，可用 `--data-dir` 或 `SHIPIOS_HOME` 指定独立目录。不会读取个人 Codex 配置或认证，也不会使用 `OPENAI_API_KEY`。

构建会执行所选项目的构建阶段，应针对自己信任的工程运行。目前是本地执行工具，尚无项目代码沙箱或 worktree 隔离；不会将构建成功标为 UI 验证通过。

桌面快捷键：`⌘N` 新任务、`⌘K` / `⌘⇧P` 命令菜单、`⌘O` 打开项目、`⌘↵` 发送、`⌘.` 停止、`⌘B` 侧栏、`⌘P` 文件搜索、`⌘J` 终端、`⌘⌥B` 审查、`⌘⇧B` 浏览器。全局“新任务”可不选文件夹直接对话；项目菜单中的“新任务”使用该项目。设置 → 模型与 API 可填写独立服务，密钥保存在 ShipiOS 专属 Keychain 中；设置 → 通用可选择模型运行时“引导当前运行”或“等待下一轮”。输入 `/chat`、`/doctor`、`/build`、`/plan` 或 `/goal` 选择会话、诊断、构建、计划或持久目标。Chat Completions 会话支持文字、图片和文本/PDF 文件附件，不自动读写项目；Codex Responses 当前支持项目内相同的输入类型，线程权限为只读。输入区加号可选择文件或图片；PDF 仅提取文字。图片需要所选模型与服务支持视觉输入。界面记录、队列与目标状态写入 `workspace.json`，非敏感模型配置写入 `model.json`，本地执行记录仍由 Agent 数据库保存。

## 已实现的代码

独立 MCP 服务可在设置 → 插件中配置和连接。支持工具调用的 API 服务会收到已连接工具的声明；真正执行前在任务内显示参数和批准/拒绝入口。工具能够执行其服务器提供的实际操作，记录与结果随任务保存。详见 [会话 MCP 调用与审批](docs/90-mcp-tool-calls-and-approval.md)。

| 位置 | 职责 |
| --- | --- |
| `crates/shipios-core` | 显式配置、来源追踪、SQLite 运行与事件存储、实例锁 |
| `crates/shipios-tools` | 有界项目扫描、参数化 Xcode 命令、进程组取消、日志与诊断 |
| `crates/shipios-agent` | CLI、JSON-RPC、任务调度、状态查询与事件重放 |
| `crates/shipios-codex` | 固定上游版本的独立配置、内存认证与线程适配；通过 Agent RPC 支持 Swift 文字、图片和文本/PDF 附件会话，完整工具与 UI 流程待接入 |
| `apps/macos` | SwiftUI/AppKit 原生工作台、Agent 生命周期、Swift 测试 |
| `clients/swift` | 可运行的 Foundation IPC 客户端探针 |
| `fixtures/HelloShipiOS` | 无外部依赖的 iOS 构建 fixture |
| `upstream/codex.lock.json` | 已审计上游源码版本；不是已链接的运行时依赖 |

## 阅读顺序

| 文档 | 内容 |
| --- | --- |
| [产品定义与范围](docs/01-product.md) | 用户、价值、MVP、用户流程、验收标准 |
| [技术架构](docs/02-architecture.md) | macOS 客户端、Rust Agent、Codex 适配、模块边界 |
| [运行环境隔离](docs/03-runtime-isolation.md) | 配置、认证、模型、Skills、MCP、环境变量与测试矩阵 |
| [工作流与接口草案](docs/04-workflows-and-contracts.md) | 状态机、工具契约、证据、失败恢复、发布授权 |
| [开发路线与任务](docs/05-roadmap.md) | 技术验证、里程碑、依赖、可执行 backlog |
| [商业与开源策略](docs/06-business-and-open-source.md) | 用户验证、定价实验、开源边界、获客 |
| [决策记录与来源](docs/07-decisions-and-evidence.md) | 用户偏好、方案演变、待定项、技术核对与纠偏 |
| [本地原型实现与验证](docs/08-local-prototype.md) | 本轮实际完成项、验证证据、隔离边界与剩余工作 |
| [桌面应用验收记录](docs/09-macos-validation.md) | 原生运行、功能矩阵、缺陷修复与复现步骤 |
| [桌面交互对齐与验收](docs/10-desktop-interactions.md) | Codex 风格工作区、任务组织、输入交互与回归结果 |
| [本轮桌面补齐与 API 配置](docs/12-desktop-parity-progress.md) | 当前实现、配置方法、原生验证、架构边界和剩余项 |
| [主窗口内页面导航修正](docs/13-in-window-navigation.md) | 设置和项目页取消独立窗口/弹窗，六个设置子页与返回状态验收；全页面对齐仍未完成 |
| [设置与键盘交互补齐](docs/14-settings-and-keyboard-interactions.md) | 快捷键搜索、改键、恢复默认、归档搜索与日期、文件搜索键盘导航及原生验收 |
| [多项目侧栏与项目菜单](docs/15-project-sidebar-interactions.md) | 独立展开、跨项目置顶、项目菜单、选择与草稿恢复，以及原生验收 |
| [自定义分组与排序](docs/16-sidebar-groups-and-ordering.md) | 分组和排序实现、持久化与测试；部分原生验收见第 23 篇 |
| [工作区面板尺寸控制](docs/17-resizable-workspace-panels.md) | 右侧宽度与终端高度调整、按项目保存、边界与恢复；原生验收见第 23 篇 |
| [Git 审查范围](docs/18-git-review-scopes.md) | 提交与基准分支比较、真实 Git 测试；原生范围切换验收见第 23 篇 |
| [逐文件差异与行内反馈](docs/19-inline-review-feedback.md) | 折叠差异、代码行评论、任务草稿与消息队列；部分原生交互验收见第 23 篇 |
| [编辑器定位与重命名文件](docs/20-editor-navigation-and-renames.md) | 主窗口内编辑器偏好、Cmd 行定位、重命名双路径处理；原生验收进展见第 23 篇 |
| [审查页分块操作](docs/21-review-hunk-actions.md) | 单块暂存、取消暂存、未暂存撤销及旧快照检查；原生验收进展见第 23 篇 |
| [批量暂存与取消暂存](docs/22-batch-staging.md) | 顶部批量操作、状态快照校验及单文件一致性修复；原生验收进展见第 23 篇 |
| [原生审查、撤销与导航验收](docs/23-native-review-validation.md) | 单文件与全部撤销、原生评论菜单修复、设置/审查/分组/面板实测与剩余边界 |
| [会话 Markdown 与复制交互](docs/24-conversation-markdown.md) | 原生块级排版、代码与整条回复复制、文件链接、窄布局和回归验收 |
| [外观设置与主窗口返回验收](docs/25-appearance-and-settings-validation.md) | 主题、字体、导入导出、终端 Esc 焦点修复与独立目录恢复 |
| [会话滚动与查找导航](docs/26-conversation-scrolling.md) | 跟随/阅读状态、返回底部、上一项查找；原生验收等待解锁 |
| [会话逐处查找与高亮](docs/27-conversation-find-occurrences.md) | 显示文本索引、重复命中、Unicode、字形定位实现；原生验收等待解锁 |
| [输入区模型与推理强度选择](docs/28-composer-model-selection.md) | 服务模型列表、搜索与键盘选择、手动 ID、请求参数验证；原生验收等待解锁 |
| [会话分叉与历史边界](docs/29-conversation-forking.md) | 整体或指定回合分叉、独立历史、来源导航与后续请求边界；原生验收等待解锁 |
| [主窗口内个性化设置](docs/30-personalization-settings.md) | 回复风格、建议提示开关、独立个人指令、迁移与主窗口原生验收 |
| [通知设置与任务跳转](docs/31-notification-settings.md) | 系统权限、完成提醒、去重与通知目标导航；真实系统通知验收等待解锁 |
| [运行时防止休眠](docs/32-prevent-idle-sleep.md) | 通用设置开关、任务生命周期、电源断言创建与释放；原生开关验收等待解锁 |
| [主窗口设置与全局命令交互](docs/33-main-window-command-routing.md) | 设置页全局弹层归属、单一弹层状态、斜杠候选键盘选择；原生逐页配对待验证 |
| [无项目新任务与会话恢复](docs/34-projectless-conversations.md) | 无文件夹会话、侧栏、队列与流式响应、跨作用域导航和重启恢复 |
| [图片附件与会话上下文](docs/35-image-attachments.md) | 图片选择/粘贴/预览、队列与分叉附件、实际多模态请求及生命周期测试 |
| [Git 分支选择与主窗口导航](docs/36-git-branch-selection.md) | 分支搜索、切换和创建、远程跟踪、修改保护与真实仓库测试 |
| [当前页面与交互验收清单](docs/37-current-page-status.md) | 各页面与全部现有设置分类的最新实现、缺失能力及待配对项 |
| [永久工作树与主窗口设置](docs/38-permanent-worktrees.md) | 项目菜单创建独立 Git 工作树、根目录配置、创建恢复、真实 Agent 与任务持久化 |
| [任务终端归属、退出与焦点](docs/39-task-terminal-sessions.md) | 任务间 Shell 隔离、首次提交接续、退出/重启、前台进程处理和焦点路由 |
| [浏览器标签与主窗口设置路由](docs/40-browser-tabs-and-settings-routing.md) | 真实网页历史、标签生命周期、地址与快捷键，以及全部设置入口复核 |
| [设置与浏览器原生交互复测](docs/41-native-settings-browser-validation.md) | 解锁后九个设置分类检查、快捷键读取恢复、浏览器连续切换与关闭的焦点修复 |
| [终端、模型弹层与启动命令原生验收](docs/42-terminal-model-native-validation.md) | 终端焦点/隔离/退出、模型搜索与配置、不可达状态及恢复期间快捷键保护 |
| [跨项目任务内容与分支搜索](docs/43-task-search-content-and-branches.md) | 历史回答/代码/诊断搜索、片段高亮、真实分支记录、后台只读历史与失败恢复 |
| [文件附件与输入区上下文](docs/44-file-attachments.md) | 文本/PDF 文件导入、预览、队列/分叉保留及实际 HTTP 内容验证 |
| [文件标签与原生焦点](docs/45-file-tabs-and-focus.md) | 文件关闭/切换、行号定位、读取竞争保护与设置返回的原生实测 |
| [多组快捷键与上下文分发](docs/46-multiple-shortcuts-and-panel-routing.md) | 多绑定编辑/搜索/冲突保护、任务与标签备用组合、文件树和审查面板切换 |
| [追加消息行为](docs/47-follow-up-steering.md) | 引导当前运行/等待下一轮、部分回复续接、队列优先级与原生流式验收 |
| [浏览器设置、历史与数据清除](docs/48-browser-settings.md) | 主窗口浏览器设置、历史搜索/打开、网站数据清除与当前能力边界 |
| [已归档任务的永久删除](docs/49-archived-task-deletion.md) | 主窗口归档设置、单条/全部删除、附件清理、tombstone 与失败回滚 |
| [主窗口用量设置与真实 token 统计](docs/50-usage-settings.md) | 独立 API 返回用量、时间图表、高用量任务、会话跳转与兼容迁移 |
| [浏览器网站权限](docs/51-browser-site-permissions.md) | 主窗口权限子页、默认访问策略、单站规则、持久化与 Agent 边界 |
| [主窗口记忆设置与模型上下文](docs/52-memory-settings.md) | 记忆启停、添加/编辑/删除、独立持久化、真实 API 上下文与原生验收 |
| [主窗口个人资料与活动洞察](docs/53-profile-settings.md) | 本地资料、头像、真实 token 活动、PNG 资料卡与主窗口原生验收 |
| [主窗口宠物设置与浮动交互](docs/54-pets-settings-and-overlay.md) | Codey/Mini、自定义图集、浮动面板、全局快捷键与重启持久化 |
| [主窗口电脑使用设置](docs/55-computer-use-settings.md) | macOS 权限状态、应用访问策略、始终允许列表与能力边界 |
| [主窗口外观主题与指针交互](docs/56-appearance-theme-parity.md) | 浅色/深色独立颜色、侧栏透明度、对比度、指针光标与跨重启验收 |
| [主窗口插件目录与本地包管理](docs/57-plugin-directory-and-local-packages.md) | 插件发现/已安装页面、本地包校验、启停、`@插件` 调用、卸载与持久化 |
| [主窗口自动化与审查队列](docs/58-main-window-automations.md) | 小时/日/周日程、启停、实际模型运行、结果任务与等待审查 |
| [主窗口连接设置与 SSH 主机发现](docs/59-main-window-connections.md) | 主窗口连接分类、显式 SSH Host 发现、OpenSSH 解析与连接测试 |
| [主窗口深链接导航](docs/60-deep-link-navigation.md) | `shipios://` 页面、设置分类和任务路由、启动恢复排队及 App URL Scheme |
| [输入区技能选择与上下文调用](docs/61-skill-mentions-and-context.md) | `$技能` 候选、重名消歧、单技能 system context 与真实请求验证 |
| [主窗口计划模式](docs/62-plan-mode.md) | `/plan`、输入模式菜单、队列与重试语义、真实模型指令和运行元数据 |
| [任务原生分享](docs/63-task-sharing.md) | macOS 分享面板、完整 Markdown 记录、本机任务链接与持久化边界 |
| [独立任务窗口](docs/64-independent-task-windows.md) | 按任务身份打开标准窗口、独立草稿与输入区、主窗口路由和原生验收 |
| [持久目标模式](docs/65-goal-mode.md) | 目标与成功标准、任务状态、受限自动续轮、暂停/完成和真实请求验证 |
| [按任务并行模型会话](docs/66-parallel-model-runs.md) | 并行流式请求、任务级停止/队列/目标续轮、跨项目窗口与完整回归 |
| [独立任务窗口会话查找](docs/67-task-window-conversation-find.md) | 窗口本地索引、匹配高亮和循环定位、快捷键与主窗口设置路由 |
| [独立任务窗口文件与终端面板](docs/68-task-window-files-and-terminal.md) | 任务项目独立文件工作区、标签与源码预览、窗口独立 PTY 和生命周期 |
| [独立任务窗口 Git 审查](docs/69-task-window-git-review.md) | 任务项目独立 Git 状态、差异与暂存、任务专属行内评论和主窗口设置路由 |
| [浏览器元素引用与任务提示历史](docs/70-browser-element-references-and-prompt-history.md) | 网页元素选择/取消/结构化引用，以及任务窗口空输入恢复本任务上一条提示 |
| [浏览器可见区域截图](docs/71-browser-visible-snapshots.md) | 真实 WebKit 可见区域截图、任务归属、附件回滚与原生预览验收 |
| [浏览器多元素与区域评论](docs/72-browser-comments.md) | 点击/拖选批注、编号标记、任务持久化与下一条模型消息上下文 |
| [浏览器下载与保存位置](docs/73-browser-downloads.md) | 真实 WebKit 下载、目录与每次询问、进度/取消、同名保护和重启恢复 |
| [浏览器右键菜单与点击目标](docs/74-browser-context-menu.md) | 链接/页面点击目标、外部或新标签页打开、WebKit 检查和 Codex 评论 |
| [浏览器标签拖排与批量关闭](docs/75-browser-tab-reordering.md) | 按真实宽度直接拖动排序、保留网页状态和关闭其他/右侧标签 |
| [重新打开关闭的浏览器标签](docs/76-browser-reopen-closed-tabs.md) | 最近关闭栈、⌘⇧T、最后标签关闭后的面板与地址恢复 |
| [任务内容标签与主窗口布局](docs/77-task-content-tabs.md) | 聊天首标签、浏览器/审查内容标签、位置快捷键、关闭恢复和完整/分栏切换 |
| [输入区教育提示与菜单栏驻留](docs/81-educational-tips-and-menu-bar.md) | 输入框上方功能提示、逐条关闭、任务草稿归属与最后窗口关闭后的菜单栏生命周期 |
| [设置导航、搜索与键盘切页](docs/82-settings-navigation-and-search.md) | 折叠导航布局修复、分组归属、设置搜索与方向键焦点导航 |
| [合并插件设置导航](docs/83-combined-plugin-settings.md) | 插件、MCP 与技能共用设置页，标签可见性、旧入口和搜索路由 |
| [插件详情页面与来源返回](docs/84-plugin-detail-navigation.md) | 主窗口详情页、来源恢复、后退前进及过期插件状态 |
| [插件技能逐项管理与预览](docs/85-individual-plugin-skills.md) | 单技能启停、真实说明预览、候选与请求上下文过滤 |
| [技能预览的立即尝试](docs/86-skill-try-now.md) | 当前项目的新任务预填、独立草稿、选择恢复与首次发送归属 |
| [独立技能导入与卸载](docs/87-standalone-skills.md) | 直接导入技能文件夹、单项管理、同名路径引用与实际请求过滤 |
| [主窗口 MCP 配置编辑](docs/88-mcp-server-settings.md) | STDIO/HTTP 页内表单、参数与变量、独立保存、启停和卸载 |
| [MCP 连接状态与工具发现](docs/89-mcp-connections-and-tools.md) | 真实 STDIO/HTTP 握手、工具分页、状态、取消重连与生命周期清理 |
| [会话 MCP 调用与任务内审批](docs/90-mcp-tool-calls-and-approval.md) | 实际模型工具调用、任务内允许/拒绝、执行结果、停止与历史恢复 |
| [审批键盘与主窗口设置菜单](docs/91-approval-keyboard-and-settings-menu.md) | Return/Esc、窗口与任务分发、输入焦点保护，以及从独立窗口唤起主窗口设置 |
| [文字与工具交错时间线](docs/92-text-and-tool-timeline.md) | 回合内事件顺序、流式文字身份、审批卡片、跨重启恢复和按段搜索 |
| [MCP 工具结果分类展示](docs/93-mcp-rich-results.md) | 纯文本、图片缩放、音频播放、资源与结构化结果，以及原始输出 |
| [MCP 编辑页保存状态](docs/94-mcp-editor-save-state.md) | 有效改动检测、文档入口、无改动保存与连接及待审批保护 |
| [Git 提交指令与说明生成](docs/95-git-commit-instructions.md) | 自动保存指令、暂存区模型请求、生成/取消、草稿和索引变化保护 |
| [提交或推送弹层](docs/96-git-commit-push.md) | 提交、提交并推送、远端选择、force-with-lease 设置及冲突保护 |
| [提交范围与新分支](docs/97-commit-selection-and-new-branch.md) | 包含未暂存变更、临时索引生成、新分支提交、取消与失败重试 |
| [提交统计与分支建议](docs/98-commit-summary-and-branch-suggestion.md) | 任务标题建议名、真实增删行统计、范围切换与异步结果归属 |
| [GitHub PR 创建](docs/99-github-pr-creation.md) | PR 弹层、默认草稿、CLI 状态、已有 PR 与不确定结果恢复 |
| [设置交互复核](docs/100-settings-search-and-keyboard-routing.md) | 主窗口设置、查找路由、搜索焦点、Esc 与输入保护 |
| [PR 自动生成与指令](docs/101-pr-generation-and-instructions.md) | PR 指令自动保存、空白字段生成、取消、上下文变化保护 |
| [设置标题与定位高亮](docs/102-settings-layout-and-search-highlight.md) | 18 页标题随内容滚动、短暂定位反馈、减少动态效果与离屏渲染检查 |
| [特殊设置页滚动结构](docs/103-special-settings-scroll-layout.md) | 插件、连接、快捷键、归档单一滚动文档，以及顶部固定搜索栏 |
| [归档筛选与项目操作](docs/104-archive-filters-and-groups.md) | 项目/类型筛选、创建与更新时间排序、分组删除及恢复回滚 |
| [归档删除弹层](docs/105-archive-deletion-dialog.md) | 主窗口居中确认、取消与键盘隔离、保存失败保留并重试 |
| [归档搜索与恢复通知](docs/106-archive-search-and-notices.md) | 1,144 组模糊搜索对照、浮动通知、计时暂停、恢复和打开失败反馈 |
| [快捷键行内录制](docs/107-shortcut-inline-capture.md) | 行内冲突、聚焦录制、独立清除绑定、主窗口重置确认与失败重试 |
| [数字快捷键](docs/108-number-shortcuts.md) | 标签/聊天修饰键交换、侧栏可见顺序、自定义绑定优先与配置迁移 |
| [外部浏览器链接快捷键](docs/109-external-browser-link-shortcut.md) | 精确修饰键点按、独立偏好、页内搜索与统一重置 |
| [回复链接呈现](docs/110-message-link-presentation.md) | 分栏/全宽、前后台标签、已开网页与页内锚点复用 |
| [回复链接下载](docs/111-message-link-downloads.md) | Option 下载、外部浏览器优先级、准备阶段取消与保存失败反馈 |
| [回复链接原生菜单](docs/112-message-link-context-menu.md) | 实际字形命中、四项菜单动作、中键映射与单次另存为 |
| [链接兼容与辅助功能](docs/113-message-link-legacy-and-accessibility.md) | macOS 14 富文本兼容、逐链接辅助功能入口、选择保持与宽度测量 |
| [启动恢复卡顿修复](docs/114-workspace-loading-feedback-loop.md) | 菜单栏状态反馈循环、相同值写入保护与原工作区实机恢复验证 |
| [设置辅助功能与焦点](docs/115-settings-accessibility-and-focus.md) | 隐藏页隔离、导航选中状态、隐藏输入框焦点保护与 Esc 返回 |
| [设置侧栏方向键](docs/116-settings-arrow-navigation.md) | 原生导航焦点、上下切页、首尾边界与搜索输入隔离 |
| [隐藏设置编辑器焦点](docs/117-settings-hidden-editor-focus.md) | 禁用编辑器退出 Tab 顺序、保留草稿、输入法与原生编辑回归 |
| [设置 Tab 循环](docs/118-settings-tab-cycle.md) | 搜索、22 项导航、表单文本字段和返回入口的正反向焦点衔接 |
| [设置开关](docs/119-settings-switch-controls.md) | 统一开关样式、Tab 导航、空格/Enter 激活与辅助功能语义 |
| [设置操作按钮](docs/120-settings-action-keyboard.md) | 表单按钮的键盘到达与激活、禁用跳过，以及完整循环的待修复问题 |
| [设置焦点分区](docs/121-settings-focus-regions.md) | 修复完整循环后的反向 Tab，核验单结果、空结果与空表单边界 |
| [设置菜单键盘操作](docs/122-settings-menu-keyboard.md) | 六个下拉菜单的 Tab、打开、选择、取消及原生控件生命周期保护 |
| [设置菜单接入范围](docs/123-settings-menu-coverage.md) | 七处设置菜单接入、辅助功能激活焦点、隐藏标签布局及待验收范围 |
| [追加消息设置按钮组](docs/124-follow-up-settings-buttons.md) | 排队/引导选项顺序、独立 Tab 焦点、空格/Enter 激活及原生验收 |
| [外观与终端位置按钮组](docs/125-appearance-and-terminal-buttons.md) | 三组控件类型与顺序修正、辅助功能激活焦点及原生键鼠验收 |
| [设置行内说明布局](docs/126-settings-inline-descriptions.md) | 16 处标题与说明合并、右侧控件居中、换行和搜索定位复核 |
| [更多设置页行内说明](docs/127-settings-description-coverage.md) | 9 页 12 处控件说明合并、Agent 加载保护及原生页面复核 |
| [自定义指令保存交互](docs/128-personalization-save-interaction.md) | 区块右侧保存、⌘S、浮动反馈、隐藏页隔离及失败重试 |
| [个性化编辑器加载与重试](docs/129-personalization-loading-and-retry.md) | 原位加载/错误提示、读取修复后重试、保存失败保留编辑器 |
| [记忆删除确认与弹层焦点](docs/130-memory-deletion-dialog.md) | 主窗口确认、失败重试、记录快照保护、默认取消与键盘焦点 |
| [确认弹层关闭后的焦点返回](docs/131-confirmation-return-focus.md) | 操作按钮焦点恢复、键盘重开、过期回调保护及项目菜单待对齐范围 |
| [归档项目菜单原生焦点](docs/132-archive-menu-focus.md) | 取消后返回菜单、空格/Enter 重开、失效回调保护及原生验收 |
| [归档类型、排序与项目菜单](docs/133-archive-filter-menus.md) | 平铺分区、独立勾选、同名项目识别、键盘选择及筛选回退 |
| [归档动作与恢复流程](docs/134-archive-actions-and-restoration.md) | 危险操作样式、恢复期间动作互斥、键盘恢复及失败重试 |
| [归档加载、错误与空状态](docs/135-archive-list-states.md) | 简洁状态行、读取失败独立呈现、无结果保留筛选和空列表隐藏动作 |
| [记忆列表搜索、排序与操作焦点](docs/136-memory-list-interactions.md) | 模糊搜索、原生排序及更多菜单、读取重试和编辑焦点返回 |
| [原生菜单禁用时序](docs/137-settings-menu-update-order.md) | 修复 SwiftUI/AppKit 焦点循环、立即禁用交互及过期更新保护 |
| [窗口内图片图库与缩放](docs/138-image-preview-gallery.md) | 附件分组切图、自然尺寸缩放、拖动、命令隔离与独立窗口焦点恢复 |
| [历史与工具图片共用图库](docs/139-image-gallery-sources-and-focus.md) | MCP 窗口内图库、原始图片保存、来源缩略图焦点与键盘重开 |
| [独立任务窗口命令归属](docs/140-task-window-command-routing.md) | 当前窗口菜单、自定义快捷键、后台预览隔离与查找焦点恢复 |
| [逐任务模型选择](docs/141-task-model-selection.md) | 独立保存模型与推理强度、请求快照、分叉继承及独立窗口选择弹层 |
| [任务重命名与窗口归属](docs/142-task-rename-dialog.md) | 窗口内弹层、名称全选、失败重试、独立窗口菜单和快捷键 |
| [重命名撤销与重做](docs/143-task-rename-undo.md) | Edit 菜单、文字撤销优先、限时历史、失败重试和任务导航 |
| [独立任务窗口内分叉](docs/144-task-window-fork.md) | 指定回复分叉、同窗口导航、草稿隔离、失败重试与跨任务撤销 |
| [独立任务窗口导航](docs/145-task-window-navigation.md) | 返回/前进、历史分支、删除任务跳过、弹层隔离及草稿恢复 |
| [任务窗口恢复](docs/146-task-window-restoration.md) | 数据目录归属、启动加载、损坏记录重试、失效窗口关闭及原生重启验收 |
| [独立任务窗口文件搜索](docs/147-task-window-file-search.md) | 当前项目搜索、⌘P 与 /files、结果打开、失败重试及焦点恢复 |
| [文件搜索窗口内弹层](docs/148-file-search-in-window-dialog.md) | 主窗口与独立窗口内搜索、快速选择竞态、焦点循环和背景命令隔离 |
| [命令菜单与任务搜索窗口内弹层](docs/149-command-and-task-search-dialogs.md) | 共用搜索弹层、即时命令执行、模式切换和原页面焦点恢复 |
| [根命令菜单统一搜索](docs/150-unified-command-menu-search.md) | 最近任务持久化、命令与任务混合结果、查询门槛和跨项目打开 |
| [浏览器标签统一搜索](docs/151-command-browser-search.md) | 当前窗口跨任务浏览器搜索、Tab 分组导航和选中行滚动 |
| [任务搜索结果快捷键](docs/152-task-search-shortcuts.md) | 置顶/最近任务分组、9 条上限、可配置结果快捷键与输入法保护 |
| [任务与命令模糊排序](docs/153-task-search-fuzzy-ranking.md) | 词首/路径匹配、字段优先级、得分排序和分段高亮 |
| [搜索结果选择与辅助功能](docs/154-search-result-selection.md) | 原生选中状态、默认首项、指针命中保护和稳定路径滚动；真实悬停待验收 |
| [文件路径模糊检索](docs/155-file-search-fuzzy-candidates.md) | nucleo 路径候选、文件名二次排序、目录打开、请求取消和空查询状态 |
| [文件搜索增量会话](docs/156-file-search-incremental-session.md) | 单窗口索引复用、部分结果、稳定选择、进程清理和失败重试 |
| [独立窗口命令与任务搜索](docs/157-task-window-command-search.md) | 当前窗口快捷键与执行、同窗口任务导航、模式切换和原焦点恢复 |
| [独立任务窗口浏览器](docs/158-task-window-browser.md) | 网页标签与搜索、回复链接、全宽切换、页面保留及截图评论归属 |
| [独立窗口文件与终端生命周期](docs/159-task-window-panel-lifetime.md) | 跨任务保留文件选区与滚动、真实终端状态及窗口关闭回收 |
| [独立窗口统一内容标签](docs/160-task-window-content-tabs.md) | 混合标签、多个终端、面板移动、关闭恢复及任务隔离 |
| [回复链接命中与后台焦点](docs/161-message-link-hit-testing-and-focus.md) | 可选择正文的中键/菜单、跨行测量、后台面板和输入焦点同步 |
| [独立窗口标签固定到侧栏](docs/162-task-window-sidebar-pins.md) | 窗口归属、原实例唤回和关闭恢复；终端焦点后续见第 163 篇 |
| [终端重新挂载焦点](docs/163-terminal-attachment-focus.md) | 按实际附着重试、取消过期请求及旧宿主隔离；侧栏唤回键盘复验见第 164 篇 |
| [共用新标签启动器](docs/164-shared-content-tab-launcher.md) | 插件条目、终端选项及窗口归属；原生菜单及终端选项已验；插件详情观察中断待查 |
| [独立窗口面板尺寸与交换方向](docs/165-task-window-panel-resizing.md) | 拖动、键盘、双击复位、逐任务尺寸及左右交换方向；原生验收通过所列路径 |
| [固定标签恢复竞态](docs/166-pinned-tab-restore-races.md) | 修复快速重复打开和加载途中取消固定；网页/终端关闭恢复与取消固定已原生验收 |
| [独立窗口投放区域](docs/167-task-window-drop-targets.md) | 隐藏面板目标、有效落点与清理；50 项回归通过，真实系统拖放仍待验收 |
| [主窗口投放与共享清理](docs/168-workspace-drop-lifecycle.md) | 隐藏侧面板/底部目标、移除 10 秒失效、共用释放清理；67 项回归通过，真实拖放仍待验收 |
| [原生标签拖动会话](docs/169-native-tab-drag-sessions.md) | 系统结束回调取代轮询、原生隐藏投放区域；75 项回归通过，原生提示/目标高亮已观察，完整释放仍待验收 |
| [主窗口标签恢复阶段性提交](docs/170-workspace-tab-restoration-checkpoint.md) | 按任务持久化布局与地址草稿；153 项回归通过，网页可见性复核见第 171 篇 |
| [网页恢复可见性复核](docs/171-browser-restoration-visibility-verification.md) | 前台原基线显示与输入通过，补真实 HTTP 冷启动回归；第二次原生重启被锁屏中断 |
| [独立任务窗口标签恢复](docs/172-task-window-tab-restoration.md) | 窗口与任务分别保存布局，173 项回归通过；手动重开后网页、新 shell、尺寸及固定标签已原生验证 |
| [系统窗口恢复验收](docs/173-system-window-restoration-verification.md) | 进程级允许恢复后，双窗口自动恢复、同任务布局隔离和跨任务固定网页按需恢复已原生验证 |
| [分离标签关闭与聊天归属](docs/174-detached-tab-owner-routing.md) | 关闭回原任务、正确聊天跳转及最小化还原；123 项回归、终端同 PID 和网页表单保留已验证 |
| [分离终端重启](docs/175-detached-terminal-restart.md) | 重启保留标签与窗口身份，替换 shell 和原生视图；128 项回归及跨任务连续重启、直接输入已验证 |
| [分离审查归属](docs/176-detached-review-ownership.md) | 审查项目、Git 操作、范围和评论绑定原任务；33 项回归及双仓库暂存隔离已验证 |
| [分离窗口恢复](docs/177-detached-window-restoration.md) | 路由保存工作区与任务归属，后台标签按需恢复；39 项回归及系统恢复、跨目录隔离已验证 |
| [分离窗口命令归属](docs/178-detached-window-command-ownership.md) | 关闭与网页快捷键作用于当前窗口，截图/评论归原任务；71 项回归及双网页原生验证通过 |
| [网页子窗口归属](docs/179-browser-child-window-ownership.md) | 新页面继承来源任务，后台网址与草稿持久化；80 项回归及原生新建、弹窗、关闭和重启验证通过 |
| [分离窗口命令菜单与任务搜索](docs/180-detached-window-search.md) | 独立搜索上下文、结果路由和焦点恢复；37 项回归及原生命令菜单、地址编辑和主窗口设置检查通过 |
| [分离窗口跨项目搜索导航](docs/181-detached-search-cross-project-navigation.md) | 等项目切换完成后置前主窗口；26 项回归及任务、附着/分离网页结果原生检查通过 |
| [网页编辑快捷键](docs/182-browser-editing-shortcuts.md) | 网页输入和地址栏保留 ⌘←/⌘→ 文本编辑，正文仍可历史导航；20 项回归及主/分离窗口原生检查通过 |
| [终端文本与字号操作](docs/183-terminal-editing-and-font.md) | 右键提供复制、粘贴、全选及字体缩放，⌘+/⌘−/⌘0 仅在终端聚焦时作用；25 项相关回归及底部终端原生检查通过 |
| [文件搜索结果归属](docs/184-file-search-result-identity.md) | 新查询未返回时不显示或打开旧查询候选；12 项相关回归通过，原生超时与锁屏后的界面复核待完成 |
| [Codex 逐页交互差异审计](docs/11-codex-ui-parity-audit.md) | 官方行为与 ShipiOS 逐项对照、缺失页面、快捷键差异和待核验项；尚未完全对齐 |
| [Codex 会话手动整理上下文](docs/215-codex-manual-compaction.md) | `/compact` 接入 Core 原生操作，覆盖双窗口、下一轮与重启续接；原生 UI 配对待验收 |
| [Codex 上下文整理时间线标记](docs/216-codex-compaction-timeline.md) | 手动与自动整理进入有序时间线，前后回复保持独立；原生视觉配对待验收 |
| [Codex 网页工具时间线](docs/217-codex-web-search-timeline.md) | 真实 Core 网页搜索事件合并为工具卡，顺序与持久化已验证；原生配对待验收 |
| [Codex 命令实时输出](docs/218-codex-live-command-output.md) | 真实 Core 命令运行中输出与首段结果合并，折叠卡可看最新行；原生配对待验收 |
| [本地 IPC v1](protocol/README.md) | 客户端握手、方法、事件、错误与断线行为 |

## 当前基线

- **用户明确偏好**：将 `codex-core + extension-api` 嵌入独立的 `shipios-agent`，模型、配置与状态独立于用户安装的 Codex。可行性仍需固定源码版本做 PoC。
- **架构草案**：SwiftUI + 少量 AppKit 客户端，Rust Agent 独立进程，产品自己管理工作流、验证与发布状态。
- **整理建议**：先验证运行时与隔离，再做“已有项目 → 构建/修复 → Simulator 冒烟验证 → 可审查结果”，随后接入 TestFlight 和提审准备。
- **商业假设**：本地执行、用户自备模型凭据、开源基础能力与商业增强；尚未验证付费意愿，也未确定许可证。

## 使用约定

文档区分“用户明确偏好”“讨论建议”“整理建议”“已核对事实”和“待验证”。未标为已确认的设计均可调整。接口名、目录结构和指标是开发草案，不代表已有功能、上游稳定 API 或对外承诺。

下一步完成 Codex Core 的工具审批、事件重放与运行中回合恢复，以及全部页面和交互配对；现有 Chat Completions 会话仍可使用，真实用户服务验证等待用户填写设置。路线图中的未来能力不代表当前二进制已经支持。
