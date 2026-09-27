# 自动化自定义日程

[OpenAI 官方 Scheduled tasks 文档](https://learn.chatgpt.com/docs/automations?surface=app)列出自定义日程控件和可编辑 RFC 5545 RRULE，并给出每月 1 日 09:00 的示例。ShipiOS 自动化编辑器现加入“自定义”频率和 RRULE 字段，显示校验错误与下次运行预览。保存时固定日程起点；改变规则或频率后重新计算，单纯修改名称、项目或指令仍保留下次运行时间。

当前本地执行器支持 `FREQ=HOURLY|DAILY|WEEKLY|MONTHLY`、`INTERVAL`、`BYDAY`、`BYMONTHDAY`（含月末倒数日期）、`BYHOUR`、`BYMINUTE`、`WKST`。输入可带 `RRULE:` 前缀。不认识的字段、重复值、越界值和未来十年无可执行日期的规则会被拒绝，不会静默忽略。旧版小时、日、周自动化继续使用原字段。此实现是 RFC 5545 的明确子集，尚不支持 `YEARLY`、`COUNT`、`UNTIL`、`BYSETPOS` 等完整规则，也没有自然语言转日程和 Codex 原生控件逐项配对。

官方文档还描述了独立计划任务按次创建新聊天、可跨多个项目、可选工作树。按次任务与逐次审查见[第 318 篇](318-automation-run-history.md)，多项目运行见[第 319 篇](319-automation-multiple-projects.md)；后台工作树仍在对齐清单中。

验证：19 项自动化测试覆盖月初、月末、隔周、月内星期、小时间隔、夏令时缺失时间、拒绝无效规则、保存与重新安排；原生应用构建和签名检查通过。锁屏仍阻止了编辑器点击及 Codex 双端视觉和焦点配对。
