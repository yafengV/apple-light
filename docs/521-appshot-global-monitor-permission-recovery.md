# Appshot 全局快捷键授权恢复

此前 Appshot 的 `NSEvent` 全局监听器只在 ShipiOS 启动时安装一次。macOS 对键盘事件监听要求辅助功能授权；如果用户启动后才在系统设置中授权，最初的监听器可能没有接收事件，应用内快捷键可用而跨应用快捷键仍无反应。[Apple 的 AppKit 文档](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents%28matching%3Ahandler%3A%29)说明了这一授权边界。

现在监听器仅在选定快捷键且系统已授权时注册。每次应用切换会重新检查授权：获得授权后重试注册，撤销授权或把快捷键设为“无”时移除监听；快捷键偏好成功保存后立即刷新。重复刷新不会安装多个监听器，首次注册失败会在下次应用切换时重试。若系统已授权但注册仍失败，Appshot 设置页会显示错误；应用内监听保持可用。

注册失败、重试、撤销、重新授权以及偏好更改在 42 项相关回归中通过；错误状态的设置页已离屏渲染检查。`script/build_and_run.sh --build-app` 正式构建及严格签名检查通过。Mac 仍锁屏，无法实际打开系统授权面板、发送跨应用按键或完成 Codex 双端操作，完整配对仍为 **0/46**。
