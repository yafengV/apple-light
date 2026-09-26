import Foundation

/// Routes one live Codex turn per task through the project Agent's private stdio channel.
@MainActor
final class CodexChatTransport {
  private let client: AgentClient
  private var generation = UUID()
  private var activeThreads: Set<String> = []
  private var streams: [String: AsyncThrowingStream<JSONValue, Error>.Continuation] = [:]

  init(client: AgentClient) {
    self.client = client
    client.onCodexEvent = { [weak self] event in self?.receive(event) }
    client.onCodexGap = { [weak self] in
      self?.reset(AgentFailure(message: "Codex 事件流中断，本轮回复无法完整确认。"))
    }
  }

  func startTurn(
    taskID: String, config: ModelConfiguration, key: String?,
    initialText: String, continuationText: String
  ) async throws -> AsyncThrowingStream<JSONValue, Error> {
    guard streams[taskID] == nil else {
      throw AgentFailure(message: "该任务已有 Codex 回合正在运行。")
    }
    guard continuationText.utf8.count <= 48_000 else {
      throw AgentFailure(message: "本轮文字超过 Codex 通道的 48 KiB 上限，请缩短后重试。")
    }
    let (stream, continuation) = AsyncThrowingStream<JSONValue, Error>.makeStream()
    streams[taskID] = continuation
    let token = generation
    do {
      let firstTurn = !activeThreads.contains(taskID)
      var sendFullContext = firstTurn
      if firstTurn {
        let thread = try await client.request("codex.thread.start", [
          "taskId": .string(taskID), "baseUrl": .string(config.baseURL),
          "model": .string(config.model), "apiKey": key.map(JSONValue.string) ?? .null,
          "initialContextBytes": .number(Double(initialText.utf8.count)),
        ])
        guard generation == token else { throw CancellationError() }
        sendFullContext = thread["resumed"].boolean != true
        activeThreads.insert(taskID)
      }
      _ = try await client.request("codex.turn.submit", [
        "taskId": .string(taskID),
        "text": .string(sendFullContext ? initialText : continuationText),
      ])
      guard generation == token else { throw CancellationError() }
      try Task.checkCancellation()
      return stream
    } catch {
      if Task.isCancelled { await interrupt(taskID: taskID) }
      streams.removeValue(forKey: taskID)?.finish(throwing: error)
      throw error
    }
  }

  func interrupt(taskID: String) async {
    guard activeThreads.contains(taskID) else { return }
    _ = try? await client.request("codex.turn.interrupt", ["taskId": .string(taskID)])
  }

  func reset(_ error: Error) {
    generation = UUID()
    activeThreads.removeAll()
    let pending = Array(streams.values)
    streams.removeAll()
    for stream in pending { stream.finish(throwing: error) }
  }

  private func receive(_ payload: JSONValue) {
    guard let taskID = payload["taskId"].text, let continuation = streams[taskID] else { return }
    let event = payload["event"]
    continuation.yield(event)
    switch event["type"].text {
    case "task_complete", "error":
      streams.removeValue(forKey: taskID)?.finish()
    default: break
    }
  }
}
