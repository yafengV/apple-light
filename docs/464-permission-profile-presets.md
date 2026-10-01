# 输入区权限预设配对

Codex 当前公开说明将“按需请求批准”定义为 `workspace-write` + `on-request`，将“完全访问”定义为 `danger-full-access` + `never`。此前 ShipiOS 输入区的完全访问只切换文件沙箱，可能留下 `on-request`，与同名 Codex 选项不同。参考：[OpenAI Sandbox 文档](https://learn.chatgpt.com/docs/sandboxing)。

主工作区、独立任务窗口和弹出首页共用同一权限选项视图。“按需请求批准”与“完全访问”会同时设置沙箱和审批策略；只读、审批和工作区网络仍可在“自定义权限”中分别调整。菜单标题按组合显示，旧配置中的 `danger-full-access` + `on-request` 显示为“自定义权限”，避免误称为完全访问。未选择覆盖时，“沿用全局设置”是唯一被勾选的项。

Agent 设置页选“完全访问”也会将审批策略改为 `never`。关闭“在输入区显示完全访问”时，全局、弹出首页及新草稿中使用完全访问的配置统一恢复为 `workspace-write` + `on-request`；已经创建的任务权限快照不变。显示开关仍需首次确认，确认仅开放选项，不直接启用。

`WorkspaceLibraryTests` 验证预设组合、旧自定义组合标题、关闭显示后的全局／弹出首页／新草稿恢复和已有任务快照。相关 55 项测试通过；`script/build_and_run.sh --verify` 正式构建启动及严格深度签名通过。Mac 仍锁屏，桌面控制不能验证前台工作区可交互，也未取得参考 Codex 与 ShipiOS 的双端逐页实操证据。因此完整配对验收保持 **0/45**。Codex 文档还列出有条件出现的“Approve for me”和命名配置；ShipiOS 目前未实现自动审批审查者或导入命名权限配置，仍属于明确差距。
