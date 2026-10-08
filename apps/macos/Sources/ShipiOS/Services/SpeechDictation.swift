import AVFoundation
import Observation
import Speech

@MainActor @Observable final class SpeechDictation {
  enum Phase: Equatable { case idle, requestingAccess, listening, finishing }
  static let waveformSampleCount = 14

  private(set) var phase = Phase.idle
  private(set) var target: String?
  private(set) var partial = ""
  private(set) var error: String?
  private(set) var errorTarget: String?
  private(set) var completedTarget: String?
  private(set) var completionID = UUID()
  private(set) var audioLevels = Array(repeating: 0.0, count: waveformSampleCount)

  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var engine: AVAudioEngine?
  @ObservationIgnored private var capture: SpeechCaptureInput?
  @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
  @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
  @ObservationIgnored private var commit: ((String, String) -> Void)?
  @ObservationIgnored private var finishTimeout: Task<Void, Never>?
  @ObservationIgnored private var inputStopped = false
  @ObservationIgnored private var completion = SpeechRecognitionCompletion()
  @ObservationIgnored private var meter: SpeechAudioLevelMeter?
  @ObservationIgnored private var recordingHistory: VoiceRecordingHistory?
  @ObservationIgnored private var recordingID: UUID?
  @ObservationIgnored private var recorder: VoiceRecordingCapture?

  static func recognitionRequest(dictionary: [String]) -> SFSpeechAudioBufferRecognitionRequest {
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = true
    request.taskHint = .dictation
    request.contextualStrings = dictionary
    return request
  }

  func start(target: String, languageIdentifier: String? = nil, microphoneDeviceID: String? = nil,
    dictionary: [String] = [], recordingHistory: VoiceRecordingHistory? = nil,
    commit: @escaping (String, String) -> Void) async {
    let token = beginSession(target: target, commit: commit)

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
    let locale = languageIdentifier.map(Locale.init(identifier:)) ?? .current
    guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable,
      recognizer.supportsOnDeviceRecognition else {
      fail("当前语言的设备端语音识别不可用，请检查系统语言或语音识别支持。", token: token)
      return
    }

    let request = Self.recognitionRequest(dictionary: dictionary)
    self.request = request
    let meter = SpeechAudioLevelMeter { [weak self] level in
      Task { @MainActor [weak self] in
        guard let self, self.generation == token, self.phase == .listening else { return }
        self.audioLevels = Array(self.audioLevels.dropFirst()) + [level]
      }
    }
    self.meter = meter
    if let microphoneDeviceID {
      guard let device = AVCaptureDevice(uniqueID: microphoneDeviceID),
        device.isConnected, device.hasMediaType(.audio) else {
        fail("所选麦克风已断开。请在语音设置中选择其他设备。", token: token)
        return
      }
      beginRecording(in: recordingHistory)
      do {
        let capture = try SpeechCaptureInput(device: device, request: request, meter: meter,
          recorder: recorder)
        self.capture = capture
        guard await capture.start() else {
          fail("无法从所选麦克风开始录音。", token: token)
          return
        }
      } catch {
        fail("无法使用所选麦克风：\(error.localizedDescription)", token: token)
        return
      }
    } else {
      guard AVCaptureDevice.default(for: .audio) != nil else {
        fail("没有可用的麦克风输入。", token: token)
        return
      }
      let engine = AVAudioEngine()
      let input = engine.inputNode
      let format = input.outputFormat(forBus: 0)
      guard format.sampleRate > 0, format.channelCount > 0 else {
        fail("没有可用的麦克风输入。", token: token)
        return
      }
      beginRecording(in: recordingHistory)
      self.engine = engine
      let recorder = self.recorder
      input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
        request.append(buffer)
        meter.append(buffer)
        recorder?.append(buffer)
      }
      do {
        engine.prepare()
        try engine.start()
      } catch {
        fail("无法开始录音：\(error.localizedDescription)", token: token)
        return
      }
    }
    guard didStartCapture(token: token) else { return }
    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      let text = result?.bestTranscription.formattedString
      let isFinal = result?.isFinal == true
      Task { @MainActor [weak self] in
        self?.receive(text: text, isFinal: isFinal, error: error, token: token)
      }
    }
  }

  /// The recognition session has an identity before requesting system access.
  /// Capture and recognition callbacks must keep using this identity.
  func beginSession(target: String, commit: @escaping (String, String) -> Void) -> UUID {
    if self.target != nil { stop() }
    let token = UUID()
    generation = token
    self.target = target
    self.commit = commit
    error = nil
    errorTarget = nil
    partial = ""
    audioLevels = Array(repeating: 0.0, count: Self.waveformSampleCount)
    completion = SpeechRecognitionCompletion()
    phase = .requestingAccess
    return token
  }

  @discardableResult func didStartCapture(token: UUID) -> Bool {
    guard generation == token, target != nil else { return false }
    phase = .listening
    return true
  }

  func stop(target expected: String? = nil, commitResult: Bool = true) {
    guard let target, expected == nil || expected == target else { return }
    let spoken = completion.stop()
    let save = commit
    let history = recordingHistory
    let recordingID = recordingID
    let recorder = recorder
    cleanup()
    if let history, let recordingID, let recorder {
      recorder.finish { size, error in
        Task { @MainActor in
          history.finish(id: recordingID, text: spoken, cancelled: !commitResult,
            sizeBytes: size, recordingError: error)
        }
      }
    }
    if commitResult && !spoken.isEmpty { save?(target, spoken) }
    completedTarget = target
    completionID = UUID()
  }

  /// Ends recording while allowing Speech to deliver its final transcription.
  func finish(target expected: String? = nil) {
    guard let target, expected == nil || expected == target else { return }
    guard phase == .listening else {
      if phase != .finishing { stop(target: target) }
      return
    }
    guard completion.beginFinishing() else { return }
    phase = .finishing
    audioLevels = Array(repeating: 0.0, count: Self.waveformSampleCount)
    endInput()
    let token = generation
    finishTimeout = Task { [weak self] in
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled else { return }
      self?.finishIfCurrent(token: token)
    }
  }

  func clearError(for target: String) {
    guard errorTarget == target else { return }
    error = nil
    errorTarget = nil
  }

  func receive(text: String?, isFinal: Bool, error: Error?, token: UUID) {
    guard generation == token, target != nil else { return }
    let completed = completion.receive(text, isFinal: isFinal, hasError: error != nil)
    partial = completion.latest
    if isFinal, completed { stop(); return }
    if let error {
      let message = "听写已中断：\(error.localizedDescription)"
      let failedTarget = target
      if completed { stop() }
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

  private func finishIfCurrent(token: UUID) {
    guard generation == token, completion.finishAfterTimeout() else { return }
    stop()
  }

  private func endInput() {
    guard !inputStopped else { return }
    inputStopped = true
    engine?.stop()
    engine?.inputNode.removeTap(onBus: 0)
    if let capture { capture.stop() }
    else {
      request?.endAudio()
      recorder?.markInputEnded()
    }
    engine = nil
    capture = nil
  }

  private func cleanup() {
    finishTimeout?.cancel()
    finishTimeout = nil
    generation = UUID()
    endInput()
    recognitionTask?.cancel()
    engine = nil
    capture = nil
    request = nil
    recognitionTask = nil
    meter = nil
    recordingHistory = nil
    recordingID = nil
    recorder = nil
    commit = nil
    target = nil
    partial = ""
    phase = .idle
    audioLevels = Array(repeating: 0.0, count: Self.waveformSampleCount)
    inputStopped = false
    completion = SpeechRecognitionCompletion()
  }

  private func beginRecording(in history: VoiceRecordingHistory?) {
    guard let history, let (id, capture) = history.begin() else { return }
    recordingHistory = history
    recordingID = id
    recorder = capture
  }
}
