import AVFoundation
import Observation
import Speech

@MainActor @Observable final class SpeechDictation {
  enum Phase: Equatable { case idle, requestingAccess, listening }

  private(set) var phase = Phase.idle
  private(set) var target: String?
  private(set) var partial = ""
  private(set) var error: String?
  private(set) var errorTarget: String?
  private(set) var completedTarget: String?
  private(set) var completionID = UUID()

  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var engine: AVAudioEngine?
  @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
  @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
  @ObservationIgnored private var commit: ((String, String) -> Void)?

  func start(target: String, commit: @escaping (String, String) -> Void) async {
    if self.target != nil { stop() }
    let token = UUID()
    generation = token
    self.target = target
    self.commit = commit
    error = nil
    errorTarget = nil
    partial = ""
    phase = .requestingAccess

    let authorization = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
    guard generation == token else { return }
    guard authorization == .authorized else {
      fail("请在系统设置中允许 ShipiOS 使用语音识别。", token: token)
      return
    }
    guard await AVCaptureDevice.requestAccess(for: .audio), generation == token else {
      if generation == token { fail("请在系统设置中允许 ShipiOS 使用麦克风。", token: token) }
      return
    }
    guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable,
      recognizer.supportsOnDeviceRecognition else {
      fail("当前语言的设备端语音识别不可用，请检查系统语言或语音识别支持。", token: token)
      return
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = true
    request.taskHint = .dictation
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      fail("没有可用的麦克风输入。", token: token)
      return
    }
    self.request = request
    self.engine = engine
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
      request.append(buffer)
    }
    do {
      engine.prepare()
      try engine.start()
    } catch {
      fail("无法开始录音：\(error.localizedDescription)", token: token)
      return
    }
    guard generation == token else { return }
    phase = .listening
    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      Task { @MainActor [weak self] in self?.receive(result: result, error: error, token: token) }
    }
  }

  func stop(target expected: String? = nil, commitResult: Bool = true) {
    guard let target, expected == nil || expected == target else { return }
    let spoken = partial.trimmingCharacters(in: .whitespacesAndNewlines)
    let save = commit
    cleanup()
    if commitResult && !spoken.isEmpty { save?(target, spoken) }
    completedTarget = target
    completionID = UUID()
  }

  func clearError(for target: String) {
    guard errorTarget == target else { return }
    error = nil
    errorTarget = nil
  }

  private func receive(result: SFSpeechRecognitionResult?, error: Error?, token: UUID) {
    guard generation == token, target != nil else { return }
    if let result { partial = result.bestTranscription.formattedString }
    if result?.isFinal == true { stop(); return }
    if let error {
      let message = "听写已中断：\(error.localizedDescription)"
      let failedTarget = target
      stop()
      self.error = message
      errorTarget = failedTarget
    }
  }

  private func fail(_ message: String, token: UUID) {
    guard generation == token else { return }
    let failedTarget = target
    stop(commitResult: false)
    error = message
    errorTarget = failedTarget
  }

  private func cleanup() {
    generation = UUID()
    engine?.stop()
    engine?.inputNode.removeTap(onBus: 0)
    request?.endAudio()
    recognitionTask?.cancel()
    engine = nil
    request = nil
    recognitionTask = nil
    commit = nil
    target = nil
    partial = ""
    phase = .idle
  }
}
