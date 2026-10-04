import Foundation
import CryptoKit

private struct MCPPersistentGrantIdentity: Encodable {
  let server: MCPServerConfiguration
  let tool: MCPToolDescription
  let inheritedEnvironment: [String: String]
}

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
    bindings: [MCPToolBinding], skills: [PluginSkillReference] = []) async throws -> ModelTokenUsage? {
    var messages = initial, transcript: [ChatMessage] = []
    let pauseAutomationID = pausableWatch(runID: runID)?.id
    let toolDefinitions = bindings.map(\.wire) + (skills.isEmpty ? [] : [ModelSkillReadTool.wire])
      + (confettiEnabled && !appearance.shouldReduceMotion ? [ModelConfettiTool.wire] : [])
      + (pauseAutomationID == nil ? [] : [ModelAutomationPauseTool.wire, ModelWatchWorktreeTool.wire])
    guard toolDefinitions.count <= 128 else {
      throw AgentFailure(message: "本轮技能与 MCP 工具合计超过 128 个，请停用不需要的服务器后重试。")
    }
    var usage: ModelTokenUsage?
    for _ in 0..<16 {
      try Task.checkCancellation()
      let prefixCount = library.chatRuns.first(where: { $0.id == runID })?.result?["response"].text?.count ?? 0
      let turn: ModelTurnResult
      do {
        turn = try await ModelAPIClient().streamTurn(config: config, key: key, messages: messages,
          attachmentRoot: dataRoot, tools: toolDefinitions) { [weak self] delta in
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
        if !toolDefinitions.isEmpty, let usage { try setChatResultField("usage", value: usage.jsonValue, runID: runID) }
      }
      let assistant = ChatMessage(role: "assistant", content: turn.text, toolCalls: turn.calls)
      messages.append(assistant); transcript.append(assistant)
      if turn.calls.isEmpty {
        if !toolDefinitions.isEmpty { try saveToolTranscript(transcript, runID: runID) }
        return usage
      }
      for (index, call) in turn.calls.enumerated() {
        do {
          let output: String
          if call.name == ModelAutomationPauseTool.name, let pauseAutomationID {
            output = try executeAutomationPauseTool(call, runID: runID, expectedAutomationID: pauseAutomationID)
          } else if call.name == ModelWatchWorktreeTool.name, let pauseAutomationID {
            output = try executeWatchWorktreeTool(call, runID: runID, expectedAutomationID: pauseAutomationID)
          } else if call.name == ModelConfettiTool.name, confettiEnabled {
            output = fireConfetti() ? "Confetti fired in the ShipiOS window." : "Confetti was suppressed by Reduce Motion or the setting changed."
          } else if call.name == ModelSkillReadTool.name, !skills.isEmpty {
            output = try executeSkillRead(call, advertised: skills, runID: runID)
          } else if let binding = bindings.first(where: { $0.alias == call.name }) {
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
      let unattended = library.chatRuns.first(where: { $0.id == runID })?
        .request["automation_id"].text != nil
      if !unattended && (mcpTaskGrants.contains(grant)
        || persistentMCPToolAllowed(serverID: binding.serverID, tool: binding.tool)) { decision = .allowOnce }
      else { decision = await requestMCPApproval(execution, runID: runID) }
      try Task.checkCancellation()
      guard decision != .deny else {
        execution.status = .denied
        let unattended = library.chatRuns.first(where: { $0.id == runID })?
          .request["automation_id"].text != nil
        execution.output = unattended
          ? "计划任务无人值守，已拒绝需要交互批准的工具调用。"
          : "用户拒绝了本次调用。未执行工具。"
        try saveToolExecution(execution, runID: runID)
        return unattended
          ? "Scheduled run cannot request interactive tool approval. No action was executed."
          : "User denied this tool call. No action was executed. Do not retry without a new user request."
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
      execution.mcpResourceActivities = execution.status == .succeeded
        ? MCPResourceActivity.extract(result, serverName: execution.serverName,
          toolName: execution.toolName) : nil
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

  private func mcpToolGrantFingerprint(serverID: UUID, tool: MCPToolDescription) -> String? {
    guard let server = mcpServers.first(where: { $0.id == serverID && $0.enabled }),
      mcpConnectionTokens[serverID] != nil,
      case .connected(_, let tools) = mcpConnectionStates[serverID],
      tools.contains(tool) else { return nil }
    let names: [String]
    switch server.transport {
    case .stdio: names = server.environmentPassthrough
    case .streamableHTTP:
      names = [server.bearerTokenEnvironmentVariable] + server.environmentHeaders.map(\.value)
    }
    let environment = ProcessInfo.processInfo.environment
    let inherited = names.filter { !$0.isEmpty }.reduce(into: [String: String]()) {
      $0[$1] = environment[$1] ?? ""
    }
    let identity = MCPPersistentGrantIdentity(server: server, tool: tool,
      inheritedEnvironment: inherited)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(identity) else { return nil }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  func persistentMCPToolAllowed(serverID: UUID, tool: MCPToolDescription) -> Bool {
    guard let fingerprint = mcpToolGrantFingerprint(serverID: serverID, tool: tool) else { return false }
    return library.mcpPersistentToolGrants[serverID.uuidString + ":" + tool.name] == fingerprint
  }

  func pruneChangedMCPPersistentToolGrants(serverID: UUID) throws {
    let prefix = serverID.uuidString + ":"
    guard case .connected(_, let tools) = mcpConnectionStates[serverID] else { return }
    var candidate = library
    for key in library.mcpPersistentToolGrants.keys where key.hasPrefix(prefix) {
      let name = String(key.dropFirst(prefix.count))
      if let tool = tools.first(where: { $0.name == name }),
        persistentMCPToolAllowed(serverID: serverID, tool: tool) { continue }
      candidate.mcpPersistentToolGrants[key] = nil
    }
    if candidate.mcpPersistentToolGrants != library.mcpPersistentToolGrants {
      try commitLibrary(candidate)
    }
  }

  @discardableResult func setPersistentMCPToolAllowed(_ allowed: Bool, serverID: UUID,
    tool: MCPToolDescription) -> Bool {
    let key = serverID.uuidString + ":" + tool.name
    let fingerprint = mcpToolGrantFingerprint(serverID: serverID, tool: tool)
    guard !allowed || fingerprint != nil else { return false }
    var candidate = library
    candidate.mcpPersistentToolGrants[key] = allowed ? fingerprint : nil
    do { try commitLibrary(candidate); mcpServersError = nil; return true }
    catch { mcpServersError = error.localizedDescription; return false }
  }

  func requestMCPApproval(
    _ execution: MCPToolExecution, runID: String,
    allowsOnce: Bool = true, allowsTask: Bool = true
  ) async -> MCPApprovalDecision {
    if library.chatRuns.first(where: { $0.id == runID })?
      .request["automation_id"].text != nil {
      pauseWatchForBlocker(runID: runID, reason: "工具 \(execution.serverName) / \(execution.toolName) 需要人工批准；无人值守回合未执行该操作。")
      return .deny
    }
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else { continuation.resume(returning: .deny); return }
        mcpPendingApprovals[execution.id] = MCPApprovalContext(runID: runID, execution: execution,
          allowsOnce: allowsOnce, allowsTask: allowsTask)
        mcpApprovalContinuations[execution.id] = continuation
        notifyAttention(runID: runID, kind: .approval, eventID: execution.id)
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.resolveMCPApproval(execution.id, decision: .deny) }
    }
  }

  func resolveMCPApproval(_ id: UUID, decision: MCPApprovalDecision) {
    guard let context = mcpPendingApprovals[id] else { return }
    if decision == .allowOnce && !context.allowsOnce { return }
    if decision == .allowTask && !context.allowsTask { return }
    guard mcpPendingApprovals.removeValue(forKey: id) != nil else { return }
    mcpApprovalContinuations.removeValue(forKey: id)?.resume(returning: decision)
  }

  func rejectMCPApprovals(serverID: UUID) {
    for (id, context) in mcpPendingApprovals where context.execution.serverID == serverID {
      resolveMCPApproval(id, decision: .deny)
    }
  }

  func saveToolExecution(_ execution: MCPToolExecution, runID: String) throws {
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

  func setChatResultField(_ key: String, value: JSONValue, runID: String) throws {
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
