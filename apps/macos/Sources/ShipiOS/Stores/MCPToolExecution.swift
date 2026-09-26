import Foundation

extension WorkspaceStore {
  func availableMCPTools() throws -> [MCPToolBinding] {
    var bindings: [MCPToolBinding] = []
    for server in mcpServers where server.enabled {
      guard case .connected(_, let tools) = mcpConnectionStates[server.id],
        let token = mcpConnectionTokens[server.id] else { continue }
      for (index, tool) in tools.sorted(by: { $0.name < $1.name }).enumerated() {
        bindings.append(MCPToolBinding(alias: "mcp_" + server.id.uuidString.replacingOccurrences(of: "-", with: "") + "_\(index)",
          serverID: server.id, serverName: server.name, connectionToken: token, tool: tool))
      }
    }
    guard bindings.count <= 128 else { throw AgentFailure(message: "已连接 MCP 工具超过 128 个，请停用不需要的服务器后重试。") }
    return bindings
  }

  func streamChatWithTools(runID: String, config: ModelConfiguration, key: String?, messages initial: [ChatMessage],
    bindings: [MCPToolBinding]) async throws -> ModelTokenUsage? {
    var messages = initial, transcript: [ChatMessage] = []
    var usage: ModelTokenUsage?
    for _ in 0..<16 {
      try Task.checkCancellation()
      let prefixCount = library.chatRuns.first(where: { $0.id == runID })?.result?["response"].text?.count ?? 0
      let turn: ModelTurnResult
      do {
        turn = try await ModelAPIClient().streamTurn(config: config, key: key, messages: messages,
          attachmentRoot: dataRoot, tools: bindings.map(\.wire)) { [weak self] delta in
            await self?.appendChat(runID, delta: delta)
          }
      } catch {
        if !transcript.isEmpty {
          let response = library.chatRuns.first(where: { $0.id == runID })?.result?["response"].text ?? ""
          let partial = String(response.dropFirst(prefixCount))
          if !partial.isEmpty { transcript.append(ChatMessage(role: "assistant", content: partial)) }
          try? saveToolTranscript(transcript, runID: runID)
        }
        throw error
      }
      if let current = turn.usage {
        if let previous = usage {
          usage = ModelTokenUsage(inputTokens: previous.inputTokens + current.inputTokens,
            outputTokens: previous.outputTokens + current.outputTokens,
            totalTokens: previous.totalTokens + current.totalTokens,
            cachedInputTokens: previous.cachedInputTokens == nil && current.cachedInputTokens == nil ? nil
              : (previous.cachedInputTokens ?? 0) + (current.cachedInputTokens ?? 0),
            reasoningOutputTokens: previous.reasoningOutputTokens == nil && current.reasoningOutputTokens == nil ? nil
              : (previous.reasoningOutputTokens ?? 0) + (current.reasoningOutputTokens ?? 0))
        } else { usage = current }
        if !bindings.isEmpty, let usage { try setChatResultField("usage", value: usage.jsonValue, runID: runID) }
      }
      let assistant = ChatMessage(role: "assistant", content: turn.text, toolCalls: turn.calls)
      messages.append(assistant); transcript.append(assistant)
      if turn.calls.isEmpty {
        if !bindings.isEmpty { try saveToolTranscript(transcript, runID: runID) }
        return usage
      }
      for (index, call) in turn.calls.enumerated() {
        do {
          let output: String
          if let binding = bindings.first(where: { $0.alias == call.name }) {
            output = try await executeMCPCall(call, binding: binding, runID: runID)
          } else { output = "Tool error: the requested tool was not offered. No action was executed." }
          let result = ChatMessage(role: "tool", content: output, toolCallID: call.id)
          messages.append(result); transcript.append(result)
        } catch {
          for remaining in turn.calls[index...] {
            transcript.append(ChatMessage(role: "tool", content: "Tool execution interrupted. Do not assume success.", toolCallID: remaining.id))
          }
          try? saveToolTranscript(transcript, runID: runID)
          throw error
        }
      }
      try saveToolTranscript(transcript, runID: runID)
      if !turn.text.isEmpty { appendChat(runID, delta: "\n\n") }
    }
    throw AgentFailure(message: "本轮已达到 16 次模型请求上限，工具记录已保留。")
  }

  private func executeMCPCall(_ call: ModelFunctionCall, binding: MCPToolBinding, runID: String) async throws -> String {
    try Task.checkCancellation()
    var execution = MCPToolExecution(callID: call.id, serverID: binding.serverID,
      serverName: binding.serverName, toolName: binding.tool.name, arguments: call.arguments)
    guard let taskID = library.task(containing: runID)?.id else { throw CancellationError() }
    let grant = taskID + ":" + binding.connectionToken.uuidString + ":" + binding.tool.name
    do {
      try validateMCPBinding(binding)
      try saveToolExecution(execution, runID: runID)
      let decision: MCPApprovalDecision
      if mcpTaskGrants.contains(grant) { decision = .allowOnce }
      else { decision = await requestMCPApproval(execution, runID: runID) }
      try Task.checkCancellation()
      guard decision != .deny else {
        execution.status = .denied
        execution.output = "用户拒绝了本次调用。未执行工具。"
        try saveToolExecution(execution, runID: runID)
        return "User denied this tool call. No action was executed. Do not retry without a new user request."
      }
      try validateMCPBinding(binding)
      if decision == .allowTask { mcpTaskGrants.insert(grant) }
      guard let connection = mcpConnections[binding.serverID] else { throw AgentFailure(message: "MCP 已断开。") }
      execution.status = .running
      try saveToolExecution(execution, runID: runID)
      let arguments = try JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8))
      let result = try await connection.callTool(binding.tool.name, arguments: arguments)
      try Task.checkCancellation()
      guard case .object = result, result["content"] != .null || result["structuredContent"] != .null else {
        throw AgentFailure(message: "MCP 工具未返回有效内容。")
      }
      execution.status = result["isError"].boolean == true ? .failed : .succeeded
      execution.output = result.pretty
      try saveToolExecution(execution, runID: runID)
      return result.pretty
    } catch {
      execution.status = Task.isCancelled ? .cancelled : .failed
      execution.output = Task.isCancelled ? "工具调用已取消；如已发出请求，服务器可能已产生副作用。" : error.localizedDescription
      try? saveToolExecution(execution, runID: runID)
      if Task.isCancelled { throw CancellationError() }
      return "Tool error: " + error.localizedDescription
    }
  }

  private func validateMCPBinding(_ binding: MCPToolBinding) throws {
    guard mcpServers.first(where: { $0.id == binding.serverID })?.enabled == true,
      mcpConnectionTokens[binding.serverID] == binding.connectionToken,
      case .connected(_, let tools) = mcpConnectionStates[binding.serverID],
      tools.contains(binding.tool) else {
      throw AgentFailure(message: "MCP 连接或工具定义已更改，本次调用未执行。")
    }
  }

  func requestMCPApproval(_ execution: MCPToolExecution, runID: String) async -> MCPApprovalDecision {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else { continuation.resume(returning: .deny); return }
        mcpPendingApprovals[execution.id] = MCPApprovalContext(runID: runID, execution: execution)
        mcpApprovalContinuations[execution.id] = continuation
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.resolveMCPApproval(execution.id, decision: .deny) }
    }
  }

  func resolveMCPApproval(_ id: UUID, decision: MCPApprovalDecision) {
    guard mcpPendingApprovals.removeValue(forKey: id) != nil else { return }
    mcpApprovalContinuations.removeValue(forKey: id)?.resume(returning: decision)
  }

  func rejectMCPApprovals(serverID: UUID) {
    for (id, context) in mcpPendingApprovals where context.execution.serverID == serverID {
      resolveMCPApproval(id, decision: .deny)
    }
  }

  private func saveToolExecution(_ execution: MCPToolExecution, runID: String) throws {
    guard let run = library.chatRuns.first(where: { $0.id == runID }) else { throw CancellationError() }
    var records = run.toolExecutions
    var items = run.responseItems ?? run.displayedResponseItems
    if let index = records.firstIndex(where: { $0.id == execution.id }) { records[index] = execution }
    else {
      records.append(execution)
      items.append(.tool(execution.id))
    }
    try setChatResultFields([
      "tool_executions": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(records)),
      "response_items": try ChatResponseItem.json(items),
    ], runID: runID)
  }

  private func saveToolTranscript(_ messages: [ChatMessage], runID: String) throws {
    try setChatResultField("tool_messages", value: try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(messages)), runID: runID)
  }

  private func setChatResultField(_ key: String, value: JSONValue, runID: String) throws {
    try setChatResultFields([key: value], runID: runID)
  }

  private func setChatResultFields(_ fields: [String: JSONValue], runID: String) throws {
    guard let index = library.chatRuns.firstIndex(where: { $0.id == runID }) else { throw CancellationError() }
    let current = library.chatRuns[index]
    var result: [String: JSONValue] = [:]
    if case .object(let fields) = current.result { result = fields }
    result.merge(fields) { _, value in value }
    let run = AgentRun(id: current.id, kind: current.kind, project: current.project, status: current.status,
      createdAt: current.createdAt, updatedAt: Date().timeIntervalSince1970 * 1000,
      request: current.request, result: .object(result))
    var candidate = library
    candidate.chatRuns[index] = run
    try commitLibrary(candidate)
    if let index = runs.firstIndex(where: { $0.id == runID }) { runs[index] = run }
  }
}
