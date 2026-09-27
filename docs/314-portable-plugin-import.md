# 便携版插件包导入

本地插件导入现支持根目录的 Agent Plugins `plugin.json`（v1 schema），并继续兼容旧版 `.codex-plugin/plugin.json`。便携版使用根目录 `name` 作为标识，可从 `extensions.com.openai.interface` 读取显示名称和简短说明；技能仍从 `skills/` 发现，`mcp.json` 的服务器数量进入组件摘要。Hooks 声明优先使用便携版 `extensions.com.openai.hooks`，缺省时再读取兼容清单，最后尝试默认 `hooks/hooks.json`。导入面板说明同步更新。

导入校验拒绝不支持的 Agent Plugins schema、缺少名称、符号链接及过大的清单。保持 ShipiOS 自有插件目录，不读取或修改用户个人 Codex 的安装。**MCP 数量目前仅为包声明摘要，插件内 MCP 运行、Hook 信任和执行尚未接通。**

依据：[OpenAI 插件打包文档](https://developers.openai.com/plugins/build/plugins)的便携版结构和兼容清单规则，以及项目固定的 Codex Core `50d77959` 的插件清单解析。验证：插件导入与 Hook 声明定向测试、应用构建和签名检查；桌面锁屏，导入面板的原生点击及双端配对尚待验收。
