import Foundation
import CryptoKit

/// Routes one live Codex turn per task through the project Agent's private stdio channel.
@MainActor
final class CodexChatTransport {
  private struct ServiceIdentity: Equatable {
    let endpoint: String
    let keyDigest: Data?

    init(config: ModelConfiguration, key: String?) {
      endpoint = config.credentialAccount
      keyDigest = key.map { Data(SHA256.hash(data: Data($0.utf8))) }
    }
  }

  private let client: AgentClient
  private let dataRoot: URL
  private var generation = UUID()
  private var activeThreads: Set<String> = []
  private var serviceIdentities: [String: ServiceIdentity] = [:]
  private var preparingTasks: Set<String> = []
  private var streams: [String: AsyncThrowingStream<JSONValue, Error>.Continuation] = [:]
  private var activeTurnIDs: [String: String] = [:]

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
    fileAppendix: String?, readOnly: Bool = false, planMode: Bool = false,
    goalInstructions: String? = nil
  ) async throws -> AsyncThrowingStream<JSONValue, Error> {
    guard streams[taskID] == nil, preparingTasks.insert(taskID).inserted else {
      throw AgentFailure(message: "该任务已有 Codex 回合正在运行。")
    }
    defer { preparingTasks.remove(taskID) }
    guard continuationText.utf8.count <= 48_000 else {
      throw AgentFailure(message: "本轮文字超过 Codex 通道的 48 KiB 上限，请缩短后重试。")
    }
    let token = generation
    let service = ServiceIdentity(config: config, key: key)
    if activeThreads.contains(taskID), serviceIdentities[taskID] != service {
      _ = try await client.request("codex.thread.stop", ["taskId": .string(taskID)])
      guard generation == token else { throw CancellationError() }
      activeThreads.remove(taskID)
      activeTurnIDs.removeValue(forKey: taskID)
      serviceIdentities.removeValue(forKey: taskID)
    }
    let staged = try fileAppendix.map(stageText)
    defer { if let staged { try? FileManager.default.removeItem(at: staged.url) } }
    let (stream, continuation) = AsyncThrowingStream<JSONValue, Error>.makeStream()
    streams[taskID] = continuation
    do {
      let firstTurn = !activeThreads.contains(taskID)
      var sendFullContext = firstTurn
      if firstTurn {
        let thread = try await client.request("codex.thread.start", [
          "taskId": .string(taskID), "baseUrl": .string(config.baseURL),
          "model": .string(config.model), "apiKey": key.map(JSONValue.string) ?? .null,
          "initialContextBytes": .number(Double(initialText.utf8.count)),
          "readOnly": .bool(readOnly),
        ])
        guard generation == token else { throw CancellationError() }
        sendFullContext = thread["resumed"].boolean != true
        activeThreads.insert(taskID)
        serviceIdentities[taskID] = service
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
        "planMode": .bool(planMode),
        "model": .string(config.model),
        "reasoningEffort": .string(config.reasoning),
      ]
      if let goalInstructions { request["goalInstructions"] = .string(goalInstructions) }
      if let staged {
        request["textAttachment"] = .object([
          "id": .string(staged.id.uuidString), "byteCount": .number(Double(staged.byteCount)),
        ])
      }
      let submitted = try await client.request("codex.turn.submit", request)
      guard generation == token else { throw CancellationError() }
      if streams[taskID] != nil { activeTurnIDs[taskID] = submitted["turnId"].text }
      try Task.checkCancellation()
      return stream
    } catch {
      if Task.isCancelled { await interrupt(taskID: taskID) }
      streams.removeValue(forKey: taskID)?.finish(throwing: error)
      throw error
    }
  }

  func steer(taskID: String, text: String, images: [ImageAttachment],
    fileAppendix: String?) async throws -> Bool {
    guard activeThreads.contains(taskID), streams[taskID] != nil,
      let expectedTurnID = activeTurnIDs[taskID] else { return false }
    guard text.utf8.count <= 48_000 else {
      throw AgentFailure(message: "追加文字超过 Codex 通道的 48 KiB 上限，请缩短后重试。")
    }
    let token = generation
    let staged = try fileAppendix.map(stageText)
    defer { if let staged { try? FileManager.default.removeItem(at: staged.url) } }
    var request: [String: JSONValue] = [
      "taskId": .string(taskID), "expectedTurnId": .string(expectedTurnID),
      "text": .string(text),
      "images": .array(images.map { image in .object([
        "id": .string(image.id.uuidString),
        "fileExtension": .string(image.fileExtension),
        "byteCount": .number(Double(image.byteCount)),
      ]) }),
    ]
    if let staged {
      request["textAttachment"] = .object([
        "id": .string(staged.id.uuidString), "byteCount": .number(Double(staged.byteCount)),
      ])
    }
    let result = try await client.request("codex.turn.steer", request)
    guard generation == token else { throw CancellationError() }
    return result["steered"].boolean == true
  }

  func canSteer(taskID: String) -> Bool {
    streams[taskID] != nil && activeTurnIDs[taskID] != nil
  }

  func interrupt(taskID: String) async {
    guard activeThreads.contains(taskID) else { return }
    _ = try? await client.request("codex.turn.interrupt", ["taskId": .string(taskID)])
  }

  func stop(taskID: String) async {
    guard activeThreads.contains(taskID) else { return }
    _ = try? await client.request("codex.thread.stop", ["taskId": .string(taskID)])
    activeThreads.remove(taskID)
    serviceIdentities.removeValue(forKey: taskID)
    activeTurnIDs.removeValue(forKey: taskID)
    streams.removeValue(forKey: taskID)?.finish()
  }

  func approve(taskID: String, id: String, turnID: String?, patch: Bool,
    decision: MCPApprovalDecision) async throws {
    guard activeThreads.contains(taskID), !id.isEmpty else {
      throw AgentFailure(message: "Codex 审批所属任务已断开。")
    }
    let choice: String
    switch decision {
    case .allowOnce: choice = "allow"
    case .allowTask: choice = "allow_for_session"
    case .deny: choice = "deny"
    }
    _ = try await client.request("codex.turn.approve", [
      "taskId": .string(taskID), "id": .string(id),
      "turnId": turnID.map(JSONValue.string) ?? .null,
      "kind": .string(patch ? "patch" : "exec"),
      "decision": .string(choice),
    ])
  }

  func answer(taskID: String, turnID: String, answers: [String: [String]]) async throws {
    guard activeThreads.contains(taskID), !turnID.isEmpty else {
      throw AgentFailure(message: "Codex 提问所属任务已断开。")
    }
    _ = try await client.request("codex.turn.answer", [
      "taskId": .string(taskID), "turnId": .string(turnID),
      "answers": .object(answers.mapValues { .array($0.map(JSONValue.string)) }),
    ])
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
    serviceIdentities.removeAll()
    activeTurnIDs.removeAll()
    let pending = Array(streams.values)
    streams.removeAll()
    for stream in pending { stream.finish(throwing: error) }
  }

  private func receive(_ payload: JSONValue) {
    guard let taskID = payload["taskId"].text, let continuation = streams[taskID] else { return }
    let event = payload["event"]
    if ["task_complete", "turn_aborted"].contains(event["type"].text ?? ""),
      let eventTurnID = event["turn_id"].text,
      let activeTurnID = activeTurnIDs[taskID], eventTurnID != activeTurnID {
      return
    }
    continuation.yield(event)
    switch event["type"].text {
    case "task_complete", "turn_aborted", "error":
      activeTurnIDs.removeValue(forKey: taskID)
      streams.removeValue(forKey: taskID)?.finish()
    default: break
    }
  }
}
