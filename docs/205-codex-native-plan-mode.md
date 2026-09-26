# Codex Responses 原生计划模式

2026-09-26。输入区的计划模式现在可用于 Codex Responses 会话。ShipiOS 将该回合设为 Codex Core 的 Plan collaboration mode，并附加只读权限；Core 自带的计划指令进入模型请求。用户在同一任务发送下一条普通消息时，回合明确切回 Default mode 和工作区写入权限。兼容 Chat Completions 会话继续使用原有计划指令。

计划回合如收到命令或补丁审批请求，会自动拒绝并在任务时间线注明“计划模式为只读”。设置页同步说明 Responses 已支持计划模式，目标模式仍待接入。

本地假服务端到端测试核对请求中的原生 Plan/Default 指令、计划回合的补丁拒绝及未写入、下一普通回合的补丁成功。此项属于代码与自动化验证；当前 Codex Mac 的计划入口、产出卡片、“按计划继续”、键盘与焦点尚未逐项原生配对，完整页面验收数不变。
