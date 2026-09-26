import Foundation

extension WorkspaceStore {
  func taskWindowRuns(_ taskID: String) -> [AgentRun] {
    guard let task = library.tasks.first(where: { $0.id == taskID }) else { return [] }
    let available = Dictionary(
      (runs + library.localRuns).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return task.runIDs.compactMap { available[$0] }
  }

  func taskWindowDraft(_ taskID: String) -> String { library.drafts[taskID] ?? "" }
  func taskWindowImages(_ taskID: String) -> [ImageAttachment] {
    library.draftImages[taskID] ?? []
  }
  func taskWindowFiles(_ taskID: String) -> [FileAttachment] {
    library.draftFiles[taskID] ?? []
  }

  func setTaskWindowDraft(_ value: String, taskID: String) {
    guard library.tasks.contains(where: { $0.id == taskID }) else { return }
    library.drafts[taskID] = value
    saveLibrary()
  }

  func restoreTaskWindowPrompt(_ taskID: String) {
    guard taskWindowDraft(taskID).isEmpty, let prompt = previousPrompt(taskID: taskID) else {
      return
    }
    setTaskWindowDraft(prompt, taskID: taskID)
  }

  func sendTaskWindowDraft(_ taskID: String, mode: ChatMode) async {
    guard let task = library.tasks.first(where: { $0.id == taskID }) else {
      error = "这个任务已经不存在。"
      return
    }
    let comments = reviewComments(taskID: taskID)
    let pageComments = browserComments(taskID: taskID)
    let prompt: String
    do {
      prompt = try promptWithBrowserComments(
        promptWithReviewComments(
          taskWindowDraft(taskID), comments: comments, project: task.project),
        comments: pageComments)
    } catch {
      self.error = error.localizedDescription
      return
    }
    guard !prompt.isEmpty || !taskWindowImages(taskID).isEmpty || !taskWindowFiles(taskID).isEmpty else {
      return
    }
    if let active = activeChatRun(taskID: taskID) {
      if active.request["api_protocol"].text == ModelAPIProtocol.codexResponses.rawValue,
        mode != .standard {
        error = "Codex Responses 的运行中追加消息当前仅支持普通模式。"
        return
      }
      let message = QueuedMessage(taskID: taskID, text: prompt,
        images: taskWindowImages(taskID), files: taskWindowFiles(taskID), mode: mode)
      var candidate = library
      if followUpBehavior == .steer,
        let first = candidate.queuedMessages.firstIndex(where: { $0.taskID == taskID }) {
        candidate.queuedMessages.insert(message, at: first)
      } else {
        candidate.queuedMessages.append(message)
      }
      candidate.drafts[taskID] = ""
      candidate.draftImages[taskID] = nil
      candidate.draftFiles[taskID] = nil
      let commentIDs = Set(comments.map(\.id))
      let pageCommentIDs = Set(pageComments.map(\.id))
      candidate.reviewComments[taskID]?.removeAll { commentIDs.contains($0.id) }
      candidate.browserComments[taskID]?.removeAll { pageCommentIDs.contains($0.id) }
      do {
        try commitLibrary(candidate)
        if followUpBehavior == .steer { await steerActiveChat(with: message) }
      } catch { self.error = error.localizedDescription }
      return
    }
    let previousRuns = Set(task.runIDs)
    await startChat(
      prompt, taskID: taskID, consumeDraft: true,
      images: taskWindowImages(taskID), files: taskWindowFiles(taskID), mode: mode)
    if let updated = library.tasks.first(where: { $0.id == taskID }),
      updated.runIDs.contains(where: { !previousRuns.contains($0) })
    {
      let commentIDs = Set(comments.map(\.id))
      let pageCommentIDs = Set(pageComments.map(\.id))
      library.reviewComments[taskID]?.removeAll { commentIDs.contains($0.id) }
      library.browserComments[taskID]?.removeAll { pageCommentIDs.contains($0.id) }
      saveLibrary()
    }
  }

  func taskWindowOwnsActiveRun(_ taskID: String) -> Bool {
    activeRun(taskID: taskID) != nil
  }
}
