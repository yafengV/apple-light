# 连接子页与插件详情深链接

[官方桌面命令参考](https://learn.chatgpt.com/docs/reference/commands#deep-links)列出连接设置的“此电脑 / 其他设备 / SSH”子路径及插件详情入口。ShipiOS 的独立 `shipios` scheme 现在支持 `shipios://settings/connections/computer`、`.../devices`、`.../ssh`，分别进入主窗口连接设置的对应分段。返回仍回到打开链接前的主窗口页面，不创建独立设置窗口。

`shipios://plugins/<已安装插件ID>` 打开本应用独立插件库中的详情；找不到该 ID 时停留在插件目录，避免显示旧详情。插件 ID 限为单个非空路径段，拒绝超长、空白、路径穿越和额外查询参数。当前没有公开市场目录和安装流程，因而未实现官方 `plugins/install` 链接，也不读取用户 Codex 的插件配置。

解析往返、无效路径、三个连接分段、详情与返回、缺失插件回退的定向测试通过；应用构建与签名检查通过。Mac 锁屏仍阻止 LaunchServices、窗口激活、焦点及当前 Codex 的双端可见验收。
