# 语音快捷键支持单独修饰键

本机 Codex macOS 客户端 26.911.61220 的语音设置中，按住听写与切换听写的快捷键控件都启用了 `allowsBareModifiers`。ShipiOS 此前只监听录制框的 `keyDown`，全局注册只使用 Carbon 带主键热键，因此无法录制或触发 `⌃`、`⌥⇧` 等绑定。

语音快捷键录制框现在额外监听 `flagsChanged`，等待整组修饰键松开后保存完整组合；若期间按下普通键，沿用已有的组合键录制。配置格式复用 `ShortcutBinding`，不会改变其他命令的快捷键校验。运行时带主键的绑定继续使用 Carbon；单独修饰键通过 AppKit 的本地和全局事件监听处理按下、释放、重复事件和按键介入。全局监听依赖 macOS 辅助功能授权，缺失时设置页会显示说明；本地监听仍可在 ShipiOS 前台工作。实现参考 [Apple 全局事件监听文档](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents%28matching%3Ahandler%3A%29)。

修饰键捕获、按住/切换状态、重新绑定、持久化和相关快捷键/设置导航共 39 项测试通过；760×650 语音页离屏图像已检查。正式应用构建与严格签名通过。本机没有可枚举麦克风，真实跨应用修饰键事件、录音、输入写回和当前 Codex 双端配对尚未实测，完整配对保持 **0/47**。
