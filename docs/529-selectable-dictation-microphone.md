# 听写麦克风选择与指定设备采集

当前 Codex 的语音设置提供麦克风选择。ShipiOS 此前只显示“系统默认”，不能选择设备，即使用户拥有多个输入设备也始终走 `AVAudioEngine` 的系统默认节点。

现在设置菜单列出 AVFoundation 可发现的音频输入设备，并把所选稳定设备 ID 保存在 ShipiOS 独立配置中。设备连接或断开时菜单更新；已保存的设备失联时保留选择并显示“所选麦克风已断开”，听写启动会报错，不会悄悄改用系统默认。旧配置继续默认跟随系统。

指定设备的听写通过 `AVCaptureDeviceInput` 和 `AVCaptureAudioDataOutput` 取得原生格式样本，按采集顺序送入 `SFSpeechAudioBufferRecognitionRequest.appendAudioSampleBuffer`。未指定设备时沿用原有 `AVAudioEngine` 路径。采集会话在后台队列启动和停止，并在已排队的音频样本处理完后结束识别输入，避免阻塞设置或输入区。

26 项语音、听写和设置导航回归通过，包含断开设备在真实原生菜单中显示为不可选项并切回系统默认；760×650 页面离屏图像、`script/build_and_run.sh --build-app` 和严格签名检查通过。本机测试进程枚举到 0 个音频输入设备，**指定设备实录、权限弹窗和最终 Codex 双端前台交互尚未验证**，完整配对仍为 **0/47**。

接口依据：[Apple 的设备 ID 说明](https://developer.apple.com/documentation/avfoundation/avcapturedevice/uniqueid)、[音频输出样本委托](https://developer.apple.com/documentation/avfoundation/avcaptureaudiodataoutput)、[Speech 样本输入](https://developer.apple.com/documentation/speech/sfspeechaudiobufferrecognitionrequest)。
