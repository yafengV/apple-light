# 听写松开后的最终结果

全局按住听写在松开时，原实现立即取消 Speech 识别任务并只提交当下的临时文本。短语音尚未返回临时文本时，输入会丢失；最终文本晚于临时文本时，也无法得到最终结果。输入区“完成”、全局切换听写和菜单栏结束入口同样受影响。

用户主动结束时，现在先停止麦克风采集并向识别请求发出 `endAudio()`，保留识别任务接收最终文本。结束期间显示“正在整理听写…”；最终结果到达即提交。若五秒内没有最终结果，则提交最新临时文本并清理；迟到结果、重复结束和旧会话回调不再二次写入。切换页面、关闭任务和应用退出仍用立即清理路径，避免旧页面的异步写回。此处理遵循 Apple 对 [音频缓冲识别请求](https://developer.apple.com/documentation/speech/sfspeechaudiobufferrecognitionrequest) 和 [识别任务完成状态](https://developer.apple.com/documentation/speech/sfspeechrecognitiontaskstate) 的说明。

17 项听写、全局快捷键、语音设置相关测试通过，包含最终文本覆盖临时文本、超时、迟到结果和错误结果。正式应用经 `script/build_and_run.sh --build-app` 构建并严格签名验证。当前机器没有可枚举麦克风，新版本前台及真实跨应用录音/输入未验收；Codex 双端逐页对照仍缺，完整配对保持 **0/47**。
