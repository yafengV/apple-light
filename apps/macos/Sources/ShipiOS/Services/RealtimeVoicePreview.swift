import Foundation
import Observation

/// Plays a short sample with the configured Realtime model without changing the saved voice.
@MainActor @Observable final class RealtimeVoicePreview {
  private(set) var activeVoiceID: String?
  private(set) var playing = false
  private(set) var error: String?

  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var networkSession: URLSession?
  @ObservationIgnored private var socket: URLSessionWebSocketTask?
  @ObservationIgnored private var receiveTask: Task<Void, Never>?
  @ObservationIgnored private var timeoutTask: Task<Void, Never>?
  @ObservationIgnored private var playback: RealtimeVoicePlayback?
  @ObservationIgnored private var responseFinished = false
  @ObservationIgnored private var receivedAudio = false
  @ObservationIgnored private let credentialReader: (String) throws -> String?

  init(credentialReader: @escaping (String) throws -> String? = ModelKeychain.read) {
    self.credentialReader = credentialReader
  }

  func toggle(config: ModelConfiguration, model: String, voice: String) {
    if activeVoiceID == voice { stop(); return }
    stop()
    let token = generation
    activeVoiceID = voice
    receiveTask = Task { [weak self] in
      await self?.run(config: config, model: model, voice: voice, token: token)
    }
    timeoutTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(30))
      guard !Task.isCancelled, let self, self.generation == token else { return }
      self.fail("音色试听超时。请检查实时语音服务。", token: token)
    }
  }

  func stop() {
    generation = UUID()
    receiveTask?.cancel()
    receiveTask = nil
    timeoutTask?.cancel()
    timeoutTask = nil
    playback?.stop()
    playback = nil
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    networkSession?.invalidateAndCancel()
    networkSession = nil
    activeVoiceID = nil
    playing = false
    error = nil
    responseFinished = false
    receivedAudio = false
  }

  private func run(config: ModelConfiguration, model: String, voice: String,
    token: UUID) async {
    do {
      let key = try credentialReader(config.credentialAccount)
      let request = try RealtimeVoiceWire.request(config: config, model: model, key: key)
      guard generation == token else { return }
      let session = URLSession(configuration: .ephemeral,
        delegate: ModelTransportDelegate(), delegateQueue: nil)
      networkSession = session
      let socket = session.webSocketTask(with: request)
      self.socket = socket
      socket.resume()
      while generation == token {
        let message = try await socket.receive()
        guard generation == token else { return }
        let bytes: Data
        switch message {
        case .data(let value): bytes = value
        case .string(let value): bytes = Data(value.utf8)
        @unknown default: continue
        }
        try await handle(RealtimeVoiceEvent.parse(bytes), socket: socket, model: model,
          voice: voice, token: token)
      }
    } catch {
      if generation == token { fail("音色试听失败：\(error.localizedDescription)", token: token) }
    }
  }

  private func handle(_ event: RealtimeVoiceEvent, socket: URLSessionWebSocketTask,
    model: String, voice: String, token: UUID) async throws {
    switch event {
    case .sessionCreated:
      try await socket.send(.data(RealtimeVoiceWire.sessionUpdate(model: model, voice: voice)))
    case .sessionUpdated:
      guard playback == nil else { return }
      playback = try RealtimeVoicePlayback { [weak self] in
        guard let self, self.generation == token, self.responseFinished else { return }
        self.stop()
      }
      try await socket.send(.data(RealtimeVoiceWire.previewPrompt()))
      try await socket.send(.data(RealtimeVoiceWire.responseCreate()))
    case .assistantAudio(let audio):
      guard let playback else { throw AgentFailure(message: "试听音频输出尚未就绪。") }
      try playback.append(audio)
      receivedAudio = true
      playing = true
      timeoutTask?.cancel()
      timeoutTask = nil
    case .responseDone(let status, let calls):
      guard status == "completed", calls.isEmpty else {
        throw AgentFailure(message: "语音服务未能生成试听音频。")
      }
      responseFinished = true
      if playback?.hasPendingAudio != true {
        if receivedAudio { stop() }
        else { throw AgentFailure(message: "语音服务没有返回试听音频。") }
      }
    case .error(let message):
      throw AgentFailure(message: String(message.prefix(500)))
    default:
      break
    }
  }

  private func fail(_ message: String, token: UUID) {
    guard generation == token else { return }
    stop()
    error = message
  }
}
