# 通知宿主的宽度与页面位置

当前 Codex 桌面分发代码的 `E2a` 将通知 portaled 到带有页面测量 inset 的固定区域，`T2a` 用 `getBoundingClientRect` 与 `ResizeObserver` 更新该区域。桌面 CSS 的 `--composer-adjacent-max-width` 由 48rem 内容宽度、两侧各 24px overhang 与两侧各 13px inset 组成，在默认 16px 根字号下为 **790px**。依据为本地已安装版本 26.911.61220/build9647 的分发文件；JS SHA-256 为 `01c04b2e5a96e5dd4c97e02ffa183f571a55bef7a221abd99404246c430f2212`，CSS SHA-256 为 `d5573a93b11a7826bf232e754d1b6353777d01c0bc067174f1701743537f9eea`。

此前 ShipiOS 的通知叠放区以整个主窗口为水平中心，并限制到 768pt；侧栏打开时，通知因此偏左。现在主窗口实测外层、详情列和工作区内容列的边界：工作区通知跟随内容列，其他页面跟随详情列，越过外层窗口的部分被裁切。通知保留在全局弹层之上，因此设置页的主题导入弹层外仍可点到通知，移除通知后同一位置重新命中弹层背景。通知宽度上限随参考 CSS 更新为 790pt。退出卡片的定时清理也在 200ms 边界后补一次检查，避免计时器略早唤醒时永久留在时间线。

纯几何及隐藏原生窗口测试验证页面边界、工作区相对侧栏的位置和裁切；主题导入回归按实测详情列点击通知，并验证弹层背景与焦点处理。59 项定向及 261 项相关回归通过，后者耗时 74.391 秒，日志分别位于 `.cache/notice-host-interaction-targeted.log` 与 `.cache/notice-host-regression.log`。`script/build_and_run.sh --build-app` 成功，日志 `.cache/notice-host-build.log`；严格深度签名通过，29 个语法资源和七份许可证逐字节一致。

本阶段没有完成 Codex 与 ShipiOS 的可见双端逐页配对；尤其宽度、视口收缩、侧栏／检查器组合及通知动画的屏幕实测仍待验收。完整配对仍为 **0/45**。
