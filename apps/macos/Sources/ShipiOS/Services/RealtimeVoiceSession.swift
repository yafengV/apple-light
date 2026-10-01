import AVFoundation
import Observation

@MainActor @Observable final class RealtimeVoiceSession {
  enum Phase: Equatable { case idle, connecting, listening, thinking, speaking, failed }

  private(set) var phase: Phase = .idle
  private(set) var muted = false
  private(set) var error: String?
  private(set) var assistantText = ""
  private(set) var userText = ""

  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var model = ""
  @ObservationIgnored private var voice = ""
  @ObservationIgnored private var networkSession: URLSession?
  @ObservationIgnored private var socket: URLSessionWebSocketTask?
  @ObservationIgnored private var receiveTask: Task<Void, Never>?
  @ObservationIgnored private var connectionTimeout: Task<Void, Never>?
  @ObservationIgnored private var sendTask: Task<Void, Never>?
  @ObservationIgnored private var audioContinuation: AsyncStream<Data>.Continuation?
  @ObservationIgnored private var capture: RealtimeVoiceCapture?
  @ObservationIgnored private var playback: RealtimeVoicePlayback?
  @ObservationIgnored private var responseFinished = false

  var isActive: Bool { phase != .idle && phase != .failed }

  func start(config: ModelConfiguration, preferences: VoicePreferences) async {
    stop()
    let token = generation
    phase = .connecting
    error = nil
    assistantText = ""
    userText = ""
    responseFinished = false
    model = preferences.realtimeModelID
    voice = preferences.realtimeVoiceID
    do {
      let key = try ModelKeychain.read(account: config.credentialAccount)
      let request = try RealtimeVoiceWire.request(config: config, model: model, key: key)
      guard await AVCaptureDevice.requestAccess(for: .audio), generation == token else {
        if generation == token { fail("请在系统设置中允许 ShipiOS 使用麦克风。", token: token) }
        return
      }
      guard microphone(for: preferences) != nil else {
        fail(preferences.microphoneDeviceID == nil ? "没有可用的麦克风输入。"
          : "所选麦克风已断开。请在语音设置中选择其他设备。", token: token)
        return
      }
      let session = URLSession(configuration: .ephemeral,
        delegate: ModelTransportDelegate(), delegateQueue: nil)
      networkSession = session
      let socket = session.webSocketTask(with: request)
      self.socket = socket
      socket.resume()
      receiveTask = Task { [weak self] in
        await self?.receiveLoop(socket: socket, preferences: preferences, token: token)
      }
      connectionTimeout = Task { [weak self] in
        try? await Task.sleep(for: .seconds(15))
        guard !Task.isCancelled, let self, self.generation == token,
          self.phase == .connecting else { return }
        self.fail("语音服务连接超时。请检查实时语音模型与 API 地址。", token: token)
      }
    } catch {
      fail(error.localizedDescription, token: token)
    }
  }

  func toggleMute() {
    guard isActive else { return }
    muted.toggle()
    capture?.setMuted(muted)
  }

  func stop() {
    generation = UUID()
    audioContinuation?.finish()
    audioContinuation = nil
    receiveTask?.cancel()
    receiveTask = nil
    connectionTimeout?.cancel()
    connectionTimeout = nil
    sendTask?.cancel()
    sendTask = nil
    capture?.stop()
    capture = nil
    playback?.stop()
    playback = nil
    responseFinished = false
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    networkSession?.invalidateAndCancel()
    networkSession = nil
    muted = false
    phase = .idle
  }

  private func microphone(for preferences: VoicePreferences) -> AVCaptureDevice? {
    if let id = preferences.microphoneDeviceID {
      guard let selected = AVCaptureDevice(uniqueID: id), selected.isConnected,
        selected.hasMediaType(.audio) else { return nil }
      return selected
    }
    return AVCaptureDevice.default(for: .audio)
  }

  private func receiveLoop(socket: URLSessionWebSocketTask, preferences: VoicePreferences,
    token: UUID) async {
    do {
      while generation == token {
        let message = try await socket.receive()
        guard generation == token else { return }
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: continue
        }
        try await handle(RealtimeVoiceEvent.parse(data), socket: socket,
          preferences: preferences, token: token)
      }
    } catch {
      if generation == token { fail("语音连接中断：\(error.localizedDescription)", token: token) }
    }
  }

  private func handle(_ event: RealtimeVoiceEvent, socket: URLSessionWebSocketTask,
    preferences: VoicePreferences, token: UUID) async throws {
    switch event {
    case .sessionCreated:
      try await socket.send(.data(RealtimeVoiceWire.sessionUpdate(model: model, voice: voice)))
    case .sessionUpdated:
      guard phase == .connecting else { return }
      try playback = RealtimeVoicePlayback { [weak self] in
        guard let self, self.generation == token, self.responseFinished else { return }
        self.phase = .listening
      }
      guard let device = microphone(for: preferences) else {
        throw AgentFailure(message: "所选麦克风已断开。")
      }
      let stream = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(16)) { continuation in
        audioContinuation = continuation
      }
      let capture = try RealtimeVoiceCapture(device: device) { [continuation = audioContinuation] bytes in
        continuation?.yield(bytes)
      }
      self.capture = capture
      guard await capture.start(), generation == token else {
        if generation == token { throw AgentFailure(message: "无法启动麦克风采集。") }
        return
      }
      connectionTimeout?.cancel()
      connectionTimeout = nil
      phase = .listening
      sendTask = Task { [weak self] in
        for await bytes in stream {
          guard let self, self.generation == token else { return }
          do { try await socket.send(.data(RealtimeVoiceWire.audioAppend(bytes))) }
          catch {
            self.fail("无法发送语音：\(error.localizedDescription)", token: token)
            return
          }
        }
      }
    case .speechStarted:
      playback?.interrupt()
      responseFinished = false
      phase = .listening
    case .speechStopped, .responseStarted:
      phase = .thinking
      if event == .responseStarted {
        responseFinished = false
        assistantText = ""
      }
    case .assistantAudio(let bytes):
      guard let playback else { throw AgentFailure(message: "语音输出尚未就绪。") }
      try playback.append(bytes)
      phase = .speaking
    case .assistantText(let delta):
      assistantText = String((assistantText + delta).prefix(12_000))
    case .userText(let text):
      userText = String(text.prefix(12_000))
    case .responseDone(let status):
      if status == "failed" {
        throw AgentFailure(message: "语音模型未能完成回复。")
      }
      responseFinished = true
      if playback?.hasPendingAudio != true { phase = .listening }
    case .error(let message):
      throw AgentFailure(message: String(message.prefix(500)))
    case .ignored:
      break
    }
  }

  private func fail(_ message: String, token: UUID) {
    guard generation == token else { return }
    stop()
    error = message
    phase = .failed
  }
}
