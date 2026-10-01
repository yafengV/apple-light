import AVFoundation

@MainActor final class RealtimeVoicePlayback {
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let format: AVAudioFormat
  private let onDrained: @MainActor () -> Void
  private var pendingBuffers = Set<UUID>()

  var hasPendingAudio: Bool { !pendingBuffers.isEmpty }

  init(onDrained: @escaping @MainActor () -> Void) throws {
    self.onDrained = onDrained
    guard let format = AVAudioFormat(standardFormatWithSampleRate: RealtimeVoiceWire.sampleRate,
      channels: 1) else {
      throw AgentFailure(message: "无法配置语音输出格式。")
    }
    self.format = format
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    engine.prepare()
    try engine.start()
    player.play()
  }

  func append(_ pcm: Data) throws {
    guard !pcm.isEmpty, pcm.count % 2 == 0, pcm.count <= 1_048_576,
      let buffer = AVAudioPCMBuffer(pcmFormat: format,
        frameCapacity: AVAudioFrameCount(pcm.count / 2)),
      let floats = buffer.floatChannelData else {
      throw AgentFailure(message: "语音服务返回了不支持的播放音频。")
    }
    buffer.frameLength = AVAudioFrameCount(pcm.count / 2)
    pcm.withUnsafeBytes { bytes in
      for frame in 0..<(pcm.count / 2) {
        let low = UInt16(bytes[frame * 2])
        let high = UInt16(bytes[frame * 2 + 1]) << 8
        floats[0][frame] = Float(Int16(bitPattern: low | high)) / 32_768
      }
    }
    let id = UUID()
    pendingBuffers.insert(id)
    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.pendingBuffers.remove(id) != nil else { return }
        if self.pendingBuffers.isEmpty { self.onDrained() }
      }
    }
    if !player.isPlaying { player.play() }
  }

  func interrupt() {
    pendingBuffers.removeAll()
    player.stop()
    player.play()
  }

  func stop() {
    pendingBuffers.removeAll()
    player.stop()
    engine.stop()
  }
}
