# Guardian 审查宿主接入

ShipiOS 已把 `approvals_reviewer = auto_review` 传给 Codex Core，但独立 `shipios-codex` 宿主只注册了浏览器工具扩展。项目固定的 Codex app-server 会额外安装 Guardian reviewer；缺少这个扩展时，普通回合仍可运行，真正的越界请求却不能完成自动审查。现在 `ThreadManager` 用弱引用注册 `codex-guardian-v2` 的 reviewer 生命周期贡献者，避免管理器与扩展互相强持有，并保持 ShipiOS 独立的 Codex home、模型服务和认证。

本地模型夹具通过实际输入区发送流程，为任务固定“自动审查批准”配置，再请求 `require_escalated` 命令。夹具的 Guardian 请求返回允许时，临时项目内文件成功写入，命令时间线为成功；返回拒绝时，文件未创建，时间线为失败并显示 Core 给出的拒绝原因。两种结果都没有留下用户审批卡，夹具状态端点确认确实收到 Guardian 审查请求。原有手动审批卡继续能批准并恢复命令。

`shipios-codex` 11 项、`shipios-agent` 12 项和上述 Swift 本地 Core 集成测试通过，Python 夹具语法、Rust 格式、`script/build_and_run.sh --verify` 正式构建启动与严格签名检查通过。自动批准测试只操作临时项目；具体审查决策由受控夹具返回，不代表真实模型的风险判断质量。Mac 仍锁屏，不能完成 ShipiOS 前台菜单、焦点和 Codex 双端交互配对；完整验收仍为 **0/45**。
