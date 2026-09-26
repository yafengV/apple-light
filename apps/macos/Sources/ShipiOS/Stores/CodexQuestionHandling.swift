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
    codexPendingQuestions[request.id] = CodexQuestionContext(runID: runID, taskID: taskID,
      request: request)
    saveLibrary()
    guard request.isBlocking else { return }
    let answers: [String: [String]]? = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else { continuation.resume(returning: nil); return }
        codexQuestionContinuations[request.id] = continuation
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancelCodexQuestion(request.id) }
    }
    try Task.checkCancellation()
    guard let answers else { throw CancellationError() }
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
    codexQuestionContinuations.removeValue(forKey: id)?.resume(returning: nil)
    updateCodexQuestion(id, runID: context.runID, status: .cancelled)
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

  private func updateCodexQuestion(_ id: UUID, runID: String, status: CodexQuestionRequest.Status) {
    guard let current = library.chatRuns.first(where: { $0.id == runID }) else { return }
    var records = current.codexQuestions
    guard let index = records.firstIndex(where: { $0.id == id }) else { return }
    records[index].status = status
    replaceChat(current, status: current.status, response: current.result?["response"].text ?? "",
      codexQuestions: records)
    saveLibrary()
  }
}
