# 子任务固定种子头像与主题变体

日期：2026-10-07。接续第 641 篇。范围保持 21 类主界面、26 类设置和 29 项核心要求；完整双端配对仍 **0/47**。

## 参考与实现

只读 Codex 26.930.51102 / build 13100 的公开安装资源，没有操作 Codex 自身前台或读取个人配置、认证与任务库。当前初始模块 SHA-256 为 22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3；子任务面板模块副本 `.cache/subagent-avatar-panel-642.js`，SHA-256 ec018b2eedae9907d6cc0a655da84ef624c86336fa0acbe7ad89271956cae4eb。

公开组件 khc 使用 Nhc 的 28 对浅/深头像，ChatGPT 调色集合为前 10 项。Ahc 按字符串 UTF-16 单元逐步执行 `(hash * 31 + unit) % 2147483647`，最后取集合长度余数。实际函数独立执行结果作为测试参照，包括代理对、规范等价但字节不同的 Unicode 和长种子；不使用 Swift 的随机 Hasher。

- 新增 `AgentAvatar` 和 `SeededAgentAvatar`，以原生子线程 ID 选择稳定的头像；按当前 colorScheme 使用浅色或深色资源，默认尺寸 24pt，无通用人形、额外圆底或模板染色。
- 56 个 SVG 随应用独立打包，NSImage 使用原生 SVG 绘制并按资源缓存。生产运行不依赖 Codex 安装位置、网络或个人目录。
- 现有共享 SubagentAvatar 用于概览行、摘要、子详情标题与投射 MCP 卡片。没有因此宣称这些区域的全部布局已对齐。
- 资源 manifest 记录顺序、原始文件/内联出处和逐文件 SHA-256；PROVENANCE 明确原始作者为 OpenAI，不把桌面艺术资源称为开源 Core 的 Apache-2.0 资源。项目许可证/分发决策仍未定案。

## 自动化与正式包

最终 helper `.cache/verified-agent-642-final/shipios-agent` 的 SHA-256 为 380bec2aac119df2c9755850f1aa6150dd14cb9403a2eb8d42eff39e7f54ae9b，与第 641 篇相同；本阶段没有 Rust 生产代码变化。

- 3 项头像测试通过：独立参考种子结果、全部 56 份资源字节/原生解码/实际绘制/主题差异及缓存复用，以及 14/24/32pt 几何。它们包含在最终关联组内，不重复累计。
- 最终 Swift 关联组 **254 项、0 失败/跳过、64.114 秒、exit 0**，`.cache/avatar-associated-642.log`；筛选 AgentAvatar|Subagent|TaskSummary|TaskWindow|CommandMenuSearchTests。
- 正式脚本构建运行、严格深度签名、IPC 与 Core RPC 冒烟通过：`.cache/avatar-formal-run-642.log`、`.cache/avatar-signature-642.log`、`.cache/avatar-ipc-642.log`、`.cache/avatar-core-rpc-642.log`。正式包内 56 份资源哈希及来源文件另已核对。
- 原生离屏联系表 `.cache/avatar-contact-sheet-642.png` 已逐项查看，全部 56 个 SVG 有实际图形；离屏检查不代替前台或双端验收。
- 原补丁审批专项连续 5 次和 10 项审批组通过，日志 `.cache/patch-approval-baseline-642.log`、`.cache/patch-approval-group-642.log`。第 641 篇两次超时仍未确认根因，不称已修复。

## 前台实操与新发现

Mac 已可交互。通过 `script/build_and_run.sh --app --data-root /private/tmp/shipios-ui-639/Data` 运行正式包：

1. 原任务 state-parent-interrupt 的概览显示 Locke、公开目标 state-child-hold、完成相对时间“1 小时 前”；浅/深主题下头像均为第 5 对资源，与同线程种子独立结果一致。
2. 点击进入同标签内详情，标题头像与概览一致，原子历史和父回复保持；返回列表和再次进入正常。
3. 中文草稿“头像验证草稿642🙂”通过粘贴输入，列表往返、设置往返和正式脚本重启后保持，未发送新回合。初次键盘 typeText 仅输入数字，未将该尝试算作中文输入验证。
4. 设置始终为同一 `ID: main`；外观切到浅色后返回详情，头像使用浅色变体；再恢复原系统模式。CUA 两次截图/窗口观测错误后，通过重新绑定及 Raise 核验实际页面，不据错误断言应用崩溃。

实操发现：从聚焦子任务输入框进入设置，返回后焦点落到父会话输入框，中文草稿本身仍保持。此项尚未修复，列为下一阶段。外观主题模式卡片在辅助功能树中也未暴露独立选项，需继续检查。

已通过正式脚本恢复默认 other 工作区，实操 ⌘, 进入同一 main 设置及 Esc 返回，原任务保持且输入器可交互。默认恢复日志 `.cache/avatar-native-default-642.log`。

运行中的连续跳秒、摘要缩略头像与投射卡片前台、全部子任务差异统计/包装、其他权限/提问、完整 V2 和其余恢复路径仍待验证/实现；本阶段前台只确认完成时间，不称第 641 篇全部时间行为已验收。

第 639 篇固定 a2216db 的原全量 session 73780 经同一 handle 确认仍运行。16 个夹具、测试二进制和冻结 helper 哈希保持；本轮仅使用 `.cache/native-ui-632`，不覆盖/重启原全量。它即使通过也不覆盖第 640—642 篇。
