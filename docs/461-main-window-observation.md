# 主窗口存在性与交互验收边界

使用 `script/build_and_run.sh --verify --data-root /private/tmp/shipios-launch-p3M4s0` 隔离启动正式签名应用后，ShipiOS 进程为 PID 33428。CoreGraphics 的 `CGWindowListCopyWindowInfo` 返回了该进程标题为“新任务”的窗口，尺寸为 1120×780，位置为 (195, 180)，窗口 ID 为 38193。因而应用创建了主窗口；此前根据辅助功能窗口数为零推断“没有创建窗口”并不成立。

同一启动中，`System Events` 返回应用可见、非前台且辅助功能窗口数为零；直接读取 `kAXWindowsAttribute` 也成功返回空列表。桌面控制接口超时；针对窗口 ID 的屏幕捕获失败。以上证据只能确认窗口在系统窗口列表中存在，不能确认其内容、加载完成或键鼠可交互。按项目约定，`script/build_and_run.sh --verify` 的进程和签名检查不能单独算启动验收通过。

Codex 参考应用的桌面控制入口明确拒绝读取，不能绕过该限制使用其他界面自动化通道。当前仍需可访问的双端可见界面和真实点击、焦点、滚动等交互证据，才能逐项关闭 21 项主工作区与 24 项设置页验收；完整配对保持 **0/45**。
