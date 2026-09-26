# Agent 会话权限

2026-09-26。Codex Mac 当前 Agent 设置提供按需批准或永不批准、只读/工作区写入/完全访问文件沙箱，以及仅在工作区写入时出现的网络开关。ShipiOS 的主窗口 Agent 设置现提供这些控制，并通过独立 Agent RPC 传入固定版 Codex Core。

默认值沿用原有行为：按需批准、工作区写入、网络受限。更改保存于 ShipiOS 工作区配置，仅影响新建的 Codex Core 线程。线程的权限写入私有恢复记录；Agent 重启续接时使用记录中的权限，而非当前新线程默认值。旧记录缺少权限字段时按原有默认值恢复。代码审查仍强制只读，即使新线程默认设置为完全访问。

Swift 设置持久化与搜索可见性相关的 25 项测试通过；Rust Core 权限映射 3 项测试和完整 Agent 测试通过，本地假模型的 Agent 桥接测试覆盖权限快照与重启续接。`script/build_and_run.sh --build-app` 构建及 App 签名验证通过。Web Search 与回复策略尚未接入，不能把该设置页认定为完整对齐。Mac 当前锁屏，新增控件还没有与当前 Codex Mac 实际页面逐项原生配对。

后续逐回合检查发现所选文件沙箱被回合设置覆盖；修复及回复设置见[第 247 篇](247-agent-response-controls-and-turn-permissions.md)。本篇记录首次接入阶段的验收范围。
