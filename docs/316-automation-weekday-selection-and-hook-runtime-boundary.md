# 多工作日自动化与便携插件 Hook 运行边界

自动化编辑器的周日程现可同时选择多个星期，至少保留一天，并按系统日历顺序显示。下一次运行取所有选定星期中最早的有效时间；修改选定日期会重新计算，单纯修改名称或指令仍保留原计划。旧版只保存一个 `weekday` 的日程继续按该日运行。保存时拒绝空集合、重复、越界或未排序日期。

此阶段仍未实现任意 RRULE、自定义间隔、应用退出后的后台调度或完整 Codex Mac 页面配对。

检查项目固定的 Codex Core `50d77959` 后，还确认了便携版 Agent Plugin Hook 的更早边界：`codex-rs/core-plugins/src/loader.rs` 对 `PluginManifestFormat::AgentPlugin` 直接给出空的 `hook_sources`，未调用 `load_plugin_hooks`。因此即使 ShipiOS 将便携插件导入并添加逐定义信任，仅配置层面也无法让这类 Hook 在任务生命周期执行。后续接入必须先修复或替换该 Core 加载路径，再隔离插件自带 MCP 等其他能力、验证执行和审计。当前 Hooks 设置页只显示声明，并明确标为不执行。

相关上游记录：[openai/codex #47925](https://github.com/openai/codex/issues/47925)。本项目的结论以上述固定版本源码为准。

验证：13 项 `AutomationTests` 全通过；`script/build_and_run.sh --build-app` 构建成功且应用签名校验通过。当前 Mac 锁屏，尚未完成页面点击和 Codex 双端配对。
