import Foundation

extension WorkspaceStore {
  func handleCodexElicitation(runID: String, taskID: String, event: JSONValue) async throws {
    let request = try CodexElicitationRequest.parse(event)
    guard let current = library.chatRuns.first(where: { $0.id == runID }) else {
      throw CancellationError()
    }
    var records = current.codexElicitations
    var items = current.responseItems ?? []
    records.append(request)
    items.append(.elicitation(request.id))
    replaceChat(current, status: current.status,
      response: current.result?["response"].text ?? "",
      responseItems: items, codexElicitations: records)
    codexPendingElicitations[request.id] = CodexElicitationContext(
      runID: runID, taskID: taskID, request: request)
    saveLibrary()
    let decision: CodexElicitationDecision? = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else { continuation.resume(returning: nil); return }
        codexElicitationContinuations[request.id] = continuation
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancelCodexElicitation(request.id) }
    }
    try Task.checkCancellation()
    guard let decision else { throw CancellationError() }
    do {
      try await codexTransport.resolveMCPElicitation(taskID: taskID,
        serverName: request.serverName, requestID: request.requestID,
        decision: decision.accepted ? .allowOnce : .deny, content: decision.content)
      updateCodexElicitation(request.id, runID: runID,
        status: decision.accepted ? .accepted : .declined)
    } catch {
      updateCodexElicitation(request.id, runID: runID, status: .cancelled)
      throw error
    }
  }

  func submitCodexElicitation(_ id: UUID, accepted: Bool, content: JSONValue?) {
    guard let context = codexPendingElicitations[id],
      !accepted || (content.map(context.request.validContent) == true) else {
      error = "请填写有效的 MCP 表单。"
      return
    }
    guard let continuation = codexElicitationContinuations.removeValue(forKey: id) else {
      error = "MCP 表单已结束，请重试该任务。"
      return
    }
    codexPendingElicitations.removeValue(forKey: id)
    continuation.resume(returning: CodexElicitationDecision(
      accepted: accepted, content: accepted ? content : nil))
  }

  func cancelCodexElicitation(_ id: UUID) {
    guard let context = codexPendingElicitations.removeValue(forKey: id) else { return }
    codexElicitationContinuations.removeValue(forKey: id)?.resume(returning: nil)
    updateCodexElicitation(id, runID: context.runID, status: .cancelled)
  }

  func expireCodexElicitations(runID: String) {
    let ids = codexPendingElicitations.compactMap { id, context in
      context.runID == runID ? id : nil
    }
    for id in ids {
      guard let context = codexPendingElicitations.removeValue(forKey: id) else { continue }
      codexElicitationContinuations.removeValue(forKey: id)?.resume(returning: nil)
      updateCodexElicitation(id, runID: context.runID, status: .expired)
    }
  }

  private func updateCodexElicitation(_ id: UUID, runID: String,
    status: CodexElicitationRequest.Status) {
    guard let current = library.chatRuns.first(where: { $0.id == runID }) else { return }
    var records = current.codexElicitations
    guard let index = records.firstIndex(where: { $0.id == id }) else { return }
    records[index].status = status
    replaceChat(current, status: current.status,
      response: current.result?["response"].text ?? "", codexElicitations: records)
    saveLibrary()
  }
}
