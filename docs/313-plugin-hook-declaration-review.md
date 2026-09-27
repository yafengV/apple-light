# 插件 Hook 声明检查

Hooks 设置页现在读取 ShipiOS 独立安装的插件包，展示命令 Hook 的事件、命令和配置来源，并明确标注“未授权执行”。支持默认 `hooks/hooks.json`、旧版 `.codex-plugin/plugin.json` 的显式路径或内联声明，以及便携版 `plugin.json` 中 `extensions.com.openai.hooks` 的覆盖声明。显式路径必须是插件内 `./` 相对路径；读取时拒绝路径穿越、符号链接和超过 256 KiB 的配置。插件启用开关仍只控制已有插件能力，**不会执行 Hook**。

这一步使用户能先检查实际定义，并避免将“包含 Hooks”误认为已经运行。后续仍需按每份当前定义建立信任记录、接入 Codex Core 生命周期、隔离错误并呈现执行审计；这些完成前，Hooks 功能仍未对齐。官方[插件打包文档](https://developers.openai.com/plugins/build/plugins)明确指出安装或启用插件不会自动信任其 Hook。

验证：5 项 Hook 读取与路径测试、已有插件回归通过；`script/build_and_run.sh --build-app` 构建成功，`codesign --verify --deep --strict dist/ShipiOS.app` 通过。当前桌面锁屏，尚未完成设置页原生点击及与 Codex Mac 的配对验收。
