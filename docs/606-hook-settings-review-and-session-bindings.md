# Hooks 来源审阅、独立决策与真实会话接入

接续第 604 篇的原生后端。本阶段将设置从仅展示声明改为可审阅、信任和逐项启停，并把当前私有定义与决策传到实际 Core 会话。完整 Codex UI 配对仍未完成，不能将本阶段当作 Hooks 整页通过。

## 参考与实现范围

当前参考包 `/Applications/ChatGPT.app/Contents/Resources/app.asar` 的公开 package metadata 为 `openai-codex-electron`、`26.930.21537`。只读取应用资源；没有读取个人 Codex 配置、登录、插件或会话。对应公开模块为 `hooks-settings-f74e8e9cf0ae.js`、`hooks-settings-model-f200bbc1bcb6.js`、`hooks-settings-source-label-817fd200ef7c.js`、`hooks-settings-copy-31e05f0310dd.js`。完整双端前台操作不以资源研究替代。

| 对照内容 | 本阶段实际行为 | 证据与边界 |
| --- | --- | --- |
| 来源分组 | 读取 ShipiOS 私有插件；同一插件的多个文件合并一个来源，文件和处理器身份独立 | 多文件真实 Agent 查询与批量决策测试；用户/项目/管理来源尚缺 |
| 设置与详情位置 | Hooks 仍在主窗口设置内；详情覆盖所属内容，不创建 settings window 或 sheet，背景操作与可访问性通过既有 modal 边界隔离 | 源码、主窗口模态状态和隐藏原生窗口渲染；前台操作尚缺 |
| 详情大小 | 按内容收缩，上限 680 点与窗口高度减 64 点；宽度上限 768 点，窄窗口内部滚动 | 1000/420 点隐藏窗口离屏图像；未确认完整像素配对 |
| 事件与处理器 | 事件按查询返回顺序分组，提供标题/描述/活跃数；每事件独立展开，单个处理器展开完整原始定义 | 原生 `session_start` 等名字转换为参考显示名；包含 MCP input、平台命令、async、匹配和上下文上限 |
| 信任与启用 | 未信任/修改后的开关禁用，分别提供单项和全部信任；信任只更新 hash，保持已有 enabled 决策 | 实际 Core hash 和独立 `Hooks/state.json`；未自动授予 managed/bypass |
| 修改、移除与批量写入 | 保存前重新发现定义并向 Agent 查询；所有条目核对完成后一次合并写入，任一过时定义拒绝整个批次 | 文件修改、插件移除、独立文件同事件索引和原子批次测试 |
| 持久化与插件启停 | 决策与安装包分开，重新读取后保留；插件停用时仍可查看/审阅，但不进入新回合绑定 | 实际磁盘恢复；写入合并保留其他来源与启停字段 |
| 键盘与退出 | Esc/⌘W 关闭，Tab/Shift-Tab 动态循环，Return/Space 激活，保留组合输入及文字复制；关闭后请求返回来源按钮焦点 | 键值、焦点顺序、页面模态阻挡测试；完整前台投递与焦点返回尚缺 |
| 大定义传输 | 私有 HookStaging 中 UUID 临时 JSON 附件，目录/文件权限、大小/类型/路径校验及消费清理；没有提高 64 KiB 入站帧上限 | 实际 Agent 的大 MCP input、重复来源、UUID/尺寸/符号链接拒绝与后续恢复 |
| 会话与变更 | 普通 Responses 回合发送最新定义/决策；定义或决策变动重建 Core 并恢复原线程；文字生成与临时 side chat 不继承 Hooks；空集合不发送新字段 | 实际应用状态→Agent→Core→shell/HTTP 三轮：未信任不执行、信任执行并提供上下文、停用后不执行，线程保持 |

原始 JSON 不通过旧声明摘要重建。插件路径稳定，定义变化不会变成全新来源而丢失“修改后未信任”的状态。JSON 配置、命令内容和 MCP 输入参与原生 hash；不是仅比较显示标签。

## 验证记录

Rust workspace 的最终源码 **164 项通过**，其中 vendor sandboxing 106 项、ShipiOS 58 项；fmt 与 Clippy 全目标 `-D warnings` 通过。实际 stdio 大定义与拒绝/恢复测试包含在其中。日志 `.cache/hook-settings-workspace-tests.log`、`.cache/hook-settings-clippy.log`。

设置与来源的 36 项专项曾通过；更广会话回归暴露了空 Hooks 新字段被旧 Agent 拒绝的问题。已修复为仅在有附件时发送新字段，保留 `.cache/hook-settings-related-tests.log` 的失败记录；该运行因后续测试直接索引空工具数组而退出 signal 5，不能记为通过。尝试定位停止时 PID 已不存在，守卫没有发送信号。修正后的 `.cache/hook-settings-related-fixed-tests.log` **129 项通过，0 失败/跳过**，236.619 秒；包含 7 项原生分叉、86 项模型传输、9 项 Hooks 和 27 项设置/插件测试。最初筛选中的 `CoreStartupCancellationTests` 不是真实类名，没有把零项匹配计入验证；后续明确选择 `CodexStartupCancellationTests`。

宽窄离屏图像验证发现事件名泄露为 `session_start` 和详情固定高度过大，已按实际 RPC 命名与参考 `max-height` 修正。它们是隐藏 NSWindow/NSHostingView 渲染，不能代替可交互前台。最终源码通过指定独立缓存的 `script/build_and_run.sh` 正式构建启动与严格深度签名验证（`.cache/hook-settings-final-app-run.log`、`.cache/hook-settings-signature.log`）。最终捆绑 Agent 的真实 IPC 诊断、事件重放、构建取消、恢复及帧上限冒烟通过（`.cache/hook-settings-ipc-smoke.log`）。

最终捆绑 Agent 的 9 项 Hooks 测试再次通过；4 项启动取消第一次仍用了包装器中的默认 Agent，因此没有冒充它们已覆盖捆绑版本。包装器已改为公共 `AgentTestExecutable`，明确捆绑版本的最终 **4 项通过，0 失败/跳过**（20.863 秒），见 `.cache/hook-settings-final-startup-tests.log`。这些复测与上述 129 项重叠，不能按运行次数叠加。

保留的全量 session 57933 使用 `f572ecf` 和默认 Rust/Swift 缓存；本阶段只用 `.cache/hooks-target` 与 `.cache/native-startup-cancel`，没有覆盖其 Agent 或重启它。即使该全量最终通过，也不代表新增源码已全量通过。

## 明确剩余项

- 当前来源在 Core 内通过私有内存 User 层绑定；**没有原生 plugin origin 和 CODEX_PLUGIN_ROOT/CODEX_PLUGIN_DATA 环境**。绝对命令与实际会话已有执行证明，依赖插件环境的处理器不能描述为已完整支持。
- 其他生命周期、PreToolUse 拦截、Permission/PostTool、Compact/Interrupt/Subagent、MCP 实际执行、async/超时/错误收尾与审计还需逐项验证。现有设置不显示完整 Hook 执行统计。
- 原生会话配置当前按启动快照执行；变更在下一次 Core 启动生效。重建旧会话的 SessionEnd 等收尾仍需验证即时停用边界，不能宣称所有生命周期热更新已完成。
- 用户/项目/管理来源、配置层覆盖冲突、全部空/错误/加载/取消和浏览器文档/外部配置入口的前台行为仍需补齐。
- Chat Completions 没有接入原生 Core Hooks；真实用户服务、前台信任/启停/展开/复制/关闭/焦点与同版本 Codex 全部对照仍缺。Mac 当前锁屏，完整配对保持 **0/47**。
