import Foundation

typealias GitTextGeneration = @Sendable ([ChatMessage]) async throws -> String

enum GitTextGenerator {
  @MainActor static func make(config: ModelConfiguration, key: String?, repository: URL,
    dataRoot: URL, executable: URL) -> GitTextGeneration {
    { messages in
      switch config.apiProtocol {
      case .chatCompletions:
        let result = try await ModelAPIClient().streamTurn(config: config, key: key,
          messages: messages, onDelta: { _ in })
        guard result.calls.isEmpty else { throw AgentFailure(message: "内容生成返回了意外的工具请求。") }
        return result.text
      case .codexResponses:
        return try await CodexTextGeneration.generate(config: config, key: key, messages: messages,
          repository: repository, dataRoot: dataRoot, executable: executable)
      }
    }
  }
}

/// A private Core process per utility call avoids changing a live coding thread or its history.
@MainActor enum CodexTextGeneration {
  static func generate(config: ModelConfiguration, key: String?, messages: [ChatMessage],
    repository: URL, dataRoot: URL, executable: URL, timeout: Duration = .seconds(180)) async throws -> String {
    try config.validateEndpoint()
    let context = String(decoding: try JSONEncoder().encode(messages), as: UTF8.self)
    guard context.utf8.count <= 1_000_000 else {
      throw AgentFailure(message: "生成内容的上下文超过 1 MB，请缩小变更或手动填写。")
    }
    let directory = dataRoot.appendingPathComponent("GitGenerations/\(UUID().uuidString)", isDirectory: true)
    let transport = CodexChatTransport(dataRoot: directory)
    let lifecycle = GitGenerationLifecycle(transport: transport)
    var timedOut = false
    let deadline = Task { @MainActor in
      do { try await Task.sleep(for: timeout) } catch { return }
      timedOut = true
      await lifecycle.shutdown()
    }
    defer { deadline.cancel() }
    do {
      let text = try await withTaskCancellationHandler {
        try Task.checkCancellation()
        let prompt = "Generate the requested text from the supplied generation messages. Return only the requested output."
        let stream = try await transport.startTurn(taskID: UUID().uuidString,
          workspace: repository, executable: executable, config: config, key: key,
          initialText: prompt, continuationText: prompt, images: [], fileAppendix: context,
          readOnly: true, textOnly: true, mcpServers: [],
          permissions: AgentRuntimePreferences(approvalPolicy: .never, sandboxMode: .readOnly),
          responses: AgentResponsePreferences(reasoningSummary: .none), webSearchMode: .disabled)
        var text = "", completed = false
        for try await event in stream {
          try Task.checkCancellation()
          switch event["type"].text {
          case "agent_message_delta": text += event["delta"].text ?? ""
          case "agent_message":
            if let value = event["message"].text { text = value }
          case "task_complete":
            if let message = event["error"]["message"].text { throw AgentFailure(message: message) }
            if text.isEmpty { text = event["last_agent_message"].text ?? "" }
            completed = true
          case "error": throw AgentFailure(message: event["message"].text ?? "内容生成失败，请重试。")
          case "turn_aborted": throw CancellationError()
          case "exec_command_begin", "patch_apply_begin", "mcp_tool_call_begin", "browser_request",
            "exec_approval_request", "apply_patch_approval_request", "request_user_input":
            throw AgentFailure(message: "内容生成返回了意外的工具请求。")
          default: break
          }
          guard text.utf8.count <= 131_072 else { throw AgentFailure(message: "模型生成的内容过大，请重试。") }
        }
        try Task.checkCancellation()
        guard completed, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw AgentFailure(message: "模型未返回完整的生成结果，请重试。")
        }
        return text
      } onCancel: {
        Task { @MainActor in await lifecycle.shutdown() }
      }
      await lifecycle.shutdown()
      try? FileManager.default.removeItem(at: directory)
      return text
    } catch {
      await lifecycle.shutdown()
      try? FileManager.default.removeItem(at: directory)
      if Task.isCancelled { throw CancellationError() }
      if timedOut { throw AgentFailure(message: "内容生成超时，请重试或手动填写。") }
      throw error
    }
  }
}

/// Cancellation, timeout and normal completion await the same process shutdown before cleanup.
@MainActor private final class GitGenerationLifecycle {
  let transport: CodexChatTransport
  private var stopTask: Task<Void, Never>?
  init(transport: CodexChatTransport) { self.transport = transport }
  func shutdown() async {
    if let stopTask { await stopTask.value; return }
    let stop = Task { await transport.shutdown() }
    stopTask = stop
    await stop.value
  }
}
