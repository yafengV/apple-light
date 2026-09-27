# 自动化高级 RRULE 扩展

[RFC 5545](https://www.rfc-editor.org/rfc/rfc5545.html)规定 `BYMONTH`、带序号的 `BYDAY` 和 `BYSETPOS` 的筛选次序。ShipiOS 的自定义日程现支持 `FREQ=YEARLY`、`BYMONTH`、月/年范围内的 `1MO` 和 `-1FR` 等序号星期、`BYSETPOS`，以及多个 `BYHOUR`、`BYMINUTE` 值。`BYSETPOS` 先在完整频率周期中确定位置，再排除起点之前的日期；例如 1 月中旬开始的“每月第一个周一”会从 2 月的第一个周一运行。

`COUNT` 与 UTC `UNTIL` 的有限日程及运行完成状态见[第 328 篇](328-automation-finite-rrule.md)。仍不接受 `BYSECOND`、`BYYEARDAY`、`BYWEEKNO` 及秒/分钟频率。旧规则仍使用原有分钟默认值，避免已保存日程无意移动。

验证：25 项自动化测试通过，覆盖每年多个月份、月内和年内序号星期、月末工作日、起点位于月中时的位置选择、多时间值、无效字段及原有夏令时边界。应用构建与签名检查通过。自定义编辑器和当前 Codex Mac 的可见交互仍待实机配对。
