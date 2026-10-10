import Foundation

extension WorkspaceStore {
  func handleCodexQuestion(runID: String, taskID: String, event: JSONValue) async throws {
    let request = try CodexQuestionRequest.parse(event)
    guard let current = library.chatRuns.first(where: { $0.id == runID }) else {
      throw CancellationError()
    }
    var records = current.codexQuestions
    var items = current.responseItems ?? []
    records.append(request)
    items.append(.question(request.id))
    replaceChat(current, status: current.status, response: current.result?["response"].text ?? "",
      responseItems: items, codexQuestions: records)
    if current.request["automation_id"].text != nil {
      pauseWatchForBlocker(runID: runID, reason: "需要用户回答：" + request.questions.map(\.question).joined(separator: "；"))
      updateCodexQuestion(request.id, runID: runID, status: .expired)
      throw AgentFailure(message: "计划任务需要回答问题；已停止本次无人值守运行，请打开结果查看。")
    }
    codexPendingQuestions[request.id] = CodexQuestionContext(runID: runID, taskID: taskID,
      request: request)
    saveLibrary()
    guard request.isBlocking else { return }
    notifyAttention(runID: runID, kind: .question, eventID: request.id)
    let answers: [String: [String]]? = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else { continuation.resume(returning: nil); return }
        codexQuestionContinuations[request.id] = continuation
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancelCodexQuestion(request.id) }
    }
    try Task.checkCancellation()
    guard let answers else {
      if library.chatRuns.first(where: { $0.id == runID })?.codexQuestions
        .first(where: { $0.id == request.id })?.status == .expired {
        throw AgentFailure(message: "Codex 提问所属会话已断开，回答请求已过期。")
      }
      throw CancellationError()
    }
    do {
      try await codexTransport.answer(taskID: taskID, turnID: request.turnID, answers: answers)
      updateCodexQuestion(request.id, runID: runID, status: .answered)
    } catch {
      updateCodexQuestion(request.id, runID: runID, status: .cancelled)
      throw error
    }
  }

  func answerCodexQuestion(_ id: UUID, answers: [String: [String]]) async {
    guard let context = codexPendingQuestions[id], context.request.validAnswers(answers) else {
      error = "请先回答所有问题。"
      return
    }
    codexPendingQuestions.removeValue(forKey: id)
    if let continuation = codexQuestionContinuations.removeValue(forKey: id) {
      continuation.resume(returning: answers)
      return
    }
    if context.request.purpose == "skill_dependencies" {
      updateCodexQuestion(id, runID: context.runID, status: .expired)
      return
    }
    do {
      try await codexTransport.answer(taskID: context.taskID, turnID: context.request.turnID,
        answers: answers)
      updateCodexQuestion(id, runID: context.runID, status: .answered)
    } catch {
      updateCodexQuestion(id, runID: context.runID, status: .expired)
      self.error = error.localizedDescription
    }
  }

  func cancelCodexQuestion(_ id: UUID) {
    guard let context = codexPendingQuestions.removeValue(forKey: id) else { return }
    if let continuation = codexQuestionContinuations.removeValue(forKey: id) {
      continuation.resume(returning: nil)
    } else if !context.request.isBlocking {
      modelTask(runID: context.runID)?.cancel()
    }
    updateCodexQuestion(id, runID: context.runID, status: .cancelled)
  }

  // The stream consumer can be suspended inside an interactive request when
  // its Agent exits. Release that wait so it can observe the failed transport.
  func expireCodexInteractiveRequests(taskID: String) {
    let runs = Set(library.tasks.first(where: { $0.id == taskID })?.runIDs ?? [])
    for runID in runs {
      expireCodexQuestions(runID: runID)
      expireCodexElicitations(runID: runID)
    }
    let approvals = mcpPendingApprovals.compactMap { id, context in
      runs.contains(context.runID) ? id : nil
    }
    for id in approvals { resolveMCPApproval(id, decision: .deny) }
  }

  func expireCodexQuestions(runID: String) {
    let ids = codexPendingQuestions.compactMap { id, context in
      context.runID == runID ? id : nil
    }
    for id in ids {
      codexPendingQuestions.removeValue(forKey: id)
      codexQuestionContinuations.removeValue(forKey: id)?.resume(returning: nil)
      updateCodexQuestion(id, runID: runID, status: .expired)
    }
  }

  func updateCodexQuestion(_ id: UUID, runID: String, status: CodexQuestionRequest.Status) {
    guard let current = library.chatRuns.first(where: { $0.id == runID }) else { return }
    var records = current.codexQuestions
    guard let index = records.firstIndex(where: { $0.id == id }) else { return }
    records[index].status = status
    replaceChat(current, status: current.status, response: current.result?["response"].text ?? "",
      codexQuestions: records)
    saveLibrary()
  }
}
