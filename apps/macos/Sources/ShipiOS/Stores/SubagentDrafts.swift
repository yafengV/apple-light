import Foundation

extension WorkspaceStore {
  func subagentDraft(_ scope: SubagentDraftScope) -> SubagentDraft? {
    guard library.tasks.contains(where: { $0.id == scope.taskID && $0.codexThreadID == scope.rootThreadID }) else { return nil }
    return library.subagentDrafts.first { $0.scope == scope }
  }

  func subagentDraftEpoch(_ scope: SubagentDraftScope) -> UUID {
    if let epoch = subagentDraftEpochs[scope] { return epoch }
    let epoch = UUID(); subagentDraftEpochs[scope] = epoch; return epoch
  }

  func invalidateSubagentDraftImports(_ scope: SubagentDraftScope) {
    subagentDraftEpochs[scope] = UUID()
  }

  func updateSubagentDraft(_ scope: SubagentDraftScope, message: ChatMessage) throws {
    try validateSubagentDraftOwner(scope)
    let previous = subagentDraft(scope)
    guard previous != nil || subagents(taskID: scope.taskID).contains(where: {
      $0.rootThreadID == scope.rootThreadID && $0.threadID == scope.childThreadID && $0.acceptsInput
    }) else { throw AgentFailure(message: "子任务已不可编辑，草稿未更改。") }
    if previous?.message == message { return }
    var record = previous ?? SubagentDraft(scope: scope, message: message)
    if record.message.content != message.content { record.contentRevision = UUID() }
    record.message = message
    let images = Set(message.images.map(\.id)), files = Set(message.files.map(\.id))
    for image in previous?.message.images ?? [] where !images.contains(image.id) { retiredSubagentDraftImages[image.id] = image }
    for file in previous?.message.files ?? [] where !files.contains(file.id) { retiredSubagentDraftFiles[file.id] = file }
    var candidate = library
    candidate.subagentDrafts.removeAll { $0.scope == scope }
    if !record.isEmpty { candidate.subagentDrafts.append(record) }
    do { try commitLibrary(candidate, updatingSubagentDraft: scope) }
    catch {
      // Keep visible input and all current references even when disk saving fails.
      // Superseded assets remain held until a later successful library save.
      library = candidate
      let message = "无法保存子任务草稿：\(error.localizedDescription)"
      subagentDraftSaveErrors[scope] = message; self.error = message
    }
  }

  func persistSubagentDraft(_ scope: SubagentDraftScope) throws {
    try validateSubagentDraftOwner(scope)
    do { try commitLibrary(library) }
    catch {
      let message = "无法保存子任务草稿：\(error.localizedDescription)"
      subagentDraftSaveErrors[scope] = message; self.error = message
      throw error
    }
  }

  private func validateSubagentDraftOwner(_ scope: SubagentDraftScope) throws {
    guard libraryLoaded, !shuttingDown,
      scope.childThreadID != scope.rootThreadID,
      library.tasks.contains(where: { $0.id == scope.taskID && $0.codexThreadID == scope.rootThreadID }) else {
      throw AgentFailure(message: "子任务所属会话已变化，草稿未更改。")
    }
  }

  /// Called only after the complete current library was successfully written.
  func finishSubagentDraftSave() {
    let images = library.imageReferences, files = library.fileReferences
    for image in retiredSubagentDraftImages.values where images[image.id] == nil {
      try? FileManager.default.removeItem(at: ImageAttachmentStorage.url(image, root: dataRoot))
    }
    for file in retiredSubagentDraftFiles.values where files[file.id] == nil {
      try? FileManager.default.removeItem(at: FileAttachmentStorage.url(file, root: dataRoot))
    }
    retiredSubagentDraftImages.removeAll(); retiredSubagentDraftFiles.removeAll()
    if let error, subagentDraftSaveErrors.values.contains(error) { self.error = nil }
    subagentDraftSaveErrors.removeAll()
    subagentDraftEpochs = subagentDraftEpochs.filter { scope, _ in
      library.tasks.contains { $0.id == scope.taskID && $0.codexThreadID == scope.rootThreadID }
    }
  }
}
