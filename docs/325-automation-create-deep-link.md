# 自动化深链接直接打开创建表单

[OpenAI 命令参考](https://learn.chatgpt.com/docs/reference/commands#scheduled)规定 `codex://automations` 打开 Scheduled 并展示创建流程。ShipiOS 对应的 `shipios://automations` 现进入主窗口自动化页并请求打开新建表单；`shipios://automations/list` 只打开列表。侧栏及普通页面导航保持列表入口。无效的自动化子路径会被拒绝。

如果应用收到链接时自动化数据仍在加载，请求会保留到页面数据可用后消费一次。测试覆盖链接解析与生成、主窗口路由、创建请求及列表入口，并通过 23 项自动化回归。应用构建与签名检查通过。桌面可见性和创建表单焦点仍待原生双端验收。
