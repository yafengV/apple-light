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
    var mode = mode
    if taskWindowDraft(taskID).trimmingCharacters(in: .whitespacesAndNewlines) == InitCommand.token {
      do {
        let prompt = try InitCommand.preparedPrompt(
          project: task.project,
          protocol: modelConfiguration(for: taskID).apiProtocol,
          hasAttachmentsOrComments: !taskWindowImages(taskID).isEmpty
            || !taskWindowFiles(taskID).isEmpty
            || !reviewComments(taskID: taskID).isEmpty
            || !browserComments(taskID: taskID).isEmpty
            || library.pullRequestCheckDrafts[taskID] != nil,
          isSideChat: task.isSideChat)
        setTaskWindowDraft(prompt, taskID: taskID)
        mode = .standard
      } catch {
        self.error = error.localizedDescription
        return
      }
    }
    if taskWindowDraft(taskID).trimmingCharacters(in: .whitespacesAndNewlines) == "/compact" {
      guard mode == .standard, canCompactConversation(taskID: taskID) else {
        error = "只有已有的空闲 Codex 会话可以整理上下文；请先移除草稿附件或结束当前回合。"
        return
      }
      await startChat("整理上下文", taskID: taskID, consumeDraft: true, compact: true)
      return
    }
    let comments = reviewComments(taskID: taskID)
    let pageComments = browserComments(taskID: taskID)
    let checkDraft = library.pullRequestCheckDrafts[taskID]
    let prompt: String
    do {
      prompt = try promptWithBrowserComments(
        promptWithReviewComments(
          taskWindowDraft(taskID), comments: comments, project: task.project, taskID: taskID),
        comments: pageComments)
      _ = try promptWithPullRequestChecks(prompt, checks: checkDraft, taskID: taskID)
    } catch {
      self.error = error.localizedDescription
      return
    }
    guard !prompt.isEmpty || !taskWindowImages(taskID).isEmpty || !taskWindowFiles(taskID).isEmpty || checkDraft != nil else {
      return
    }
    if let active = activeChatRun(taskID: taskID) {
      if active.request["api_protocol"].text == ModelAPIProtocol.codexResponses.rawValue,
        mode != .standard {
        error = "Codex Responses 的运行中追加消息当前仅支持普通模式。"
        return
      }
      let message = QueuedMessage(taskID: taskID, text: prompt,
        images: taskWindowImages(taskID), files: taskWindowFiles(taskID), mode: mode, pullRequestChecks: checkDraft)
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
      if candidate.pullRequestCheckDrafts[taskID] == checkDraft { candidate.pullRequestCheckDrafts[taskID] = nil }
      do {
        try commitLibrary(candidate)
        if followUpBehavior == .steer { await steerActiveChat(with: message) }
      } catch { self.error = error.localizedDescription }
      return
    }
    let previousRuns = Set(task.runIDs)
    await startChat(
      prompt, taskID: taskID, consumeDraft: true,
      images: taskWindowImages(taskID), files: taskWindowFiles(taskID), mode: mode, pullRequestChecks: checkDraft)
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

  func canRerunTaskWindowChat(_ run: AgentRun, taskID: String) -> Bool {
    guard case .object = run.request else { return false }
    return run.kind == "chat" && !run.isActive
      && library.tasks.first(where: { $0.id == taskID })?.runIDs.contains(run.id) == true
      && canStartChat(taskID: taskID)
  }

  func rerunTaskWindowChat(_ run: AgentRun, taskID: String) async {
    guard canRerunTaskWindowChat(run, taskID: taskID), case .object(let request) = run.request else {
      return
    }
    if request["conversation_kind"]?.text == "review" {
      do {
        let originalID = library.forkRunOrigins[run.id] ?? run.id
        let snapshot = try ReviewSnapshotStorage.load(runID: originalID, root: dataRoot)
        guard request["review_scope"]?.text == snapshot.scope.metadataValue,
          request["review_selection"]?.text == snapshot.scope.selection,
          let delivery = request["review_delivery"]?.text.flatMap(ReviewDelivery.init(rawValue:)) else {
          throw AgentFailure(message: "原审查范围已失效，无法重新运行。")
        }
        await startChat(snapshot.requestTitle, taskID: taskID,
          review: ModelCodeReviewContext(snapshot: snapshot, delivery: delivery))
      } catch { self.error = error.localizedDescription }
      return
    }
    await startChat(library.notes[run.id] ?? "", taskID: taskID,
      images: library.runImages[run.id] ?? [], files: library.runFiles[run.id] ?? [],
      mode: ChatMode(rawValue: request["mode"]?.text ?? "") ?? .standard)
  }
}
