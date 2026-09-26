import Foundation

/// Routes one live Codex turn per task through the project Agent's private stdio channel.
@MainActor
final class CodexChatTransport {
  private let client: AgentClient
  private let dataRoot: URL
  private var generation = UUID()
  private var activeThreads: Set<String> = []
  private var streams: [String: AsyncThrowingStream<JSONValue, Error>.Continuation] = [:]

  init(client: AgentClient, dataRoot: URL) {
    self.client = client
    self.dataRoot = dataRoot
    client.onCodexEvent = { [weak self] event in self?.receive(event) }
    client.onCodexGap = { [weak self] in
      self?.reset(AgentFailure(message: "Codex 事件流中断，本轮回复无法完整确认。"))
    }
  }

  func startTurn(
    taskID: String, config: ModelConfiguration, key: String?,
    initialText: String, continuationText: String, images: [ImageAttachment],
    fileAppendix: String?
  ) async throws -> AsyncThrowingStream<JSONValue, Error> {
    guard streams[taskID] == nil else {
      throw AgentFailure(message: "该任务已有 Codex 回合正在运行。")
    }
    guard continuationText.utf8.count <= 48_000 else {
      throw AgentFailure(message: "本轮文字超过 Codex 通道的 48 KiB 上限，请缩短后重试。")
    }
    let staged = try fileAppendix.map(stageText)
    defer { if let staged { try? FileManager.default.removeItem(at: staged.url) } }
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
      let wireImages: [JSONValue] = images.map { image in .object([
        "id": .string(image.id.uuidString),
        "fileExtension": .string(image.fileExtension),
        "byteCount": .number(Double(image.byteCount)),
      ]) }
      var request: [String: JSONValue] = [
        "taskId": .string(taskID),
        "text": .string(sendFullContext ? initialText : continuationText),
        "images": .array(wireImages),
      ]
      if let staged {
        request["textAttachment"] = .object([
          "id": .string(staged.id.uuidString), "byteCount": .number(Double(staged.byteCount)),
        ])
      }
      _ = try await client.request("codex.turn.submit", request)
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

  private func stageText(_ text: String) throws -> (id: UUID, url: URL, byteCount: Int) {
    let bytes = Data(text.utf8)
    guard !bytes.isEmpty, bytes.count <= 1_000_000 else {
      throw AgentFailure(message: "文件提取文本超过 Codex 通道的 1 MB 上限，请减少附件。")
    }
    let directory = dataRoot.appendingPathComponent("CodexStaging", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
      throw AgentFailure(message: "临时附件目录无效。")
    }
    let id = UUID()
    let url = directory.appendingPathComponent(id.uuidString + ".txt")
    do {
      try bytes.write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
      try? FileManager.default.removeItem(at: url)
      throw error
    }
    return (id, url, bytes.count)
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
