# 自动审查批准权限预设

[Codex 权限文档](https://learn.chatgpt.com/docs/sandboxing)说明，“Approve for me”用于符合条件的审批请求；沙箱边界与审批者是不同的控制。项目固定的 Codex Core 版本支持 `approvals_reviewer = auto_review`，也支持每轮通过 `ThreadSettingsOverrides` 切换审批者。ShipiOS 此前只提供用户审批与“永不请求批准”，无法选这个预设。

输入区、独立任务窗口和弹出首页共用“自动审查批准”预设：`workspace-write` + `on-request` + `auto_review`，网络仍由沙箱限制。自定义权限增加审批者选择；Agent 设置页增加全局默认值和搜索定位。Swift 工作区保存审批者，旧工作区 JSON 无该字段时解码为 `user`。Swift IPC 在新建会话及每轮提交时发送 `approvalReviewer`；Rust Agent 解析后将它设置到 Codex Core 的初始配置及每轮覆盖。文本生成的只读内部会话仍固定由用户审查者配置，不使用自动审查。

Rust 协议测试验证 `auto_review` 序列化与旧请求默认值，`shipios-codex` 11 项及 `shipios-agent` 12 项测试通过；后者需要回环端口权限，受限沙箱内的两项本地服务测试不能绑定端口。Swift 34 项相关测试验证预设、旧数据迁移、草稿持久化和设置搜索。本地模型夹具的真实 Core 会话在同一任务中先以只读模式执行，再切换到自动审查预设并成功在工作区写入。`script/build_and_run.sh --verify` 正式构建启动及严格签名检查通过。Mac 仍锁屏，不能确认工作区前台可交互。后续[第 466 篇](466-guardian-review-host-integration.md)补上宿主 Guardian 扩展并验证真实越界请求的批准与拒绝；Codex 双端前台配对仍待完成，完整验收保持 **0/45**。
