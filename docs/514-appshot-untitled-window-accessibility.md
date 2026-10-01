# Appshot 无标题窗口辅助功能匹配

此前 Appshot 的辅助功能采集要求 ScreenCaptureKit 返回非空窗口标题，并要求该应用只有一个完全同名的辅助功能窗口。无标题窗口、重名窗口，以及截图与辅助功能标题不同步时，截图可以附上，但文字上下文总为空。

现在先用唯一标题识别窗口；标题缺失、重复或与目标矩形不符时，再按屏幕矩形的重叠率寻找唯一候选。若多个辅助功能窗口的矩形相同或与截图矩形距离过大，就不读取其文字，以免把同一应用的另一窗口内容误附到截图。确定目标后，优先把辅助功能窗口标题写入最终 Appshot 上下文。窗口筛选和树遍历共用 1.5 秒截止时间，取消截图时会取消辅助功能任务。

坐标判断依据：[Apple 对辅助功能位置的定义](https://developer.apple.com/documentation/applicationservices/kaxpositionattribute)使用主屏幕左上角为原点；[ScreenCaptureKit 的 SCWindow](https://developer.apple.com/documentation/screencapturekit/scwindow)提供目标窗口矩形与标题。是否在所有显示器排列和所有目标应用中一致，仍须前台验证。

21 项 Appshot 定向测试、`script/build_and_run.sh --build-app`、严格深度签名及差异检查通过。Mac 仍锁屏，无法获取真实目标窗口的辅助功能树，也无法对照 Codex 前台截图与标题。当前 Codex 的默认双击 Command 全局截取快捷键、截图去向与声音设置也尚未在 ShipiOS 中实现；45 类页面与交互的完整配对验收仍为 **0/45**。
