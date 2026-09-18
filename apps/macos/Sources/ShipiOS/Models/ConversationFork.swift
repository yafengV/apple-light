import Foundation

struct ConversationForkOrigin: Codable, Equatable {
  let taskID: String
  let runID: String
}

extension WorkspaceLibrary {
  /// Snapshot history into distinct records: a run ID must belong to one task.
  mutating func forkConversation(
    taskID: String, through runID: String? = nil, availableRuns: [AgentRun]
  ) throws -> WorkspaceTask {
    guard let source = tasks.first(where: { $0.id == taskID }) else {
      throw AgentFailure(message: "找不到要分叉的任务。")
    }
    let end: Int
    if let runID {
      guard let index = source.runIDs.firstIndex(of: runID) else {
        throw AgentFailure(message: "该回合不属于当前任务。")
      }
      end = index + 1
    } else {
      end = source.runIDs.firstIndex { id in
        availableRuns.first(where: { $0.id == id })?.isActive == true
      } ?? source.runIDs.count
    }
    let ids = Array(source.runIDs.prefix(end))
    guard !ids.isEmpty else { throw AgentFailure(message: "至少需要一个已结束的回合才能分叉。") }
    var snapshots: [AgentRun] = []
    var origins: [String: String] = [:]
    var copiedNotes: [String: String] = [:]
    var copiedBranches: [String: String] = [:]
    var copiedFiles: [String: [FileAttachment]] = [:]
    var copiedImages: [String: [ImageAttachment]] = [:]
    for id in ids {
      guard let run = availableRuns.first(where: { $0.id == id }),
        run.project == source.project, !run.isActive
      else { throw AgentFailure(message: "历史尚未完整加载或包含进行中的回合，无法分叉。") }
      let newID = UUID().uuidString
      snapshots.append(AgentRun(
        id: newID, kind: run.kind, project: run.project, status: run.status,
        createdAt: run.createdAt, updatedAt: run.updatedAt, request: run.request, result: run.result))
      origins[newID] = forkRunOrigins[id] ?? id
      copiedNotes[newID] = notes[id]
      copiedBranches[newID] = runBranches[id]
      copiedImages[newID] = runImages[id]
      copiedFiles[newID] = runFiles[id]
    }
    let now = Date()
    let fork = WorkspaceTask(
      id: UUID().uuidString, project: source.project,
      title: String(source.title.prefix(112)) + " · 分叉", runIDs: snapshots.map(\.id),
      forkOrigin: ConversationForkOrigin(taskID: source.id, runID: ids.last!), createdAt: now, updatedAt: now)
    tasks.insert(fork, at: 0)
    forkRuns.append(contentsOf: snapshots)
    forkRunOrigins.merge(origins) { _, new in new }
    notes.merge(copiedNotes) { _, new in new }
    runBranches.merge(copiedBranches) { _, new in new }
    runImages.merge(copiedImages) { _, new in new }
    runFiles.merge(copiedFiles) { _, new in new }
    return fork
  }

  func chatContext(taskID: String?) -> [ChatMessage] {
    let ids = tasks.first(where: { $0.id == taskID })?.runIDs ?? []
    let stored = Dictionary(localRuns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return ids.flatMap { id -> [ChatMessage] in
      guard let run = stored[id], run.kind == "chat" else { return [] }
      var messages = [ChatMessage(role: "user", content: notes[id] ?? "", images: runImages[id] ?? [], files: runFiles[id] ?? [])]
      if let transcript = try? run.result?["tool_messages"].decode([ChatMessage].self), !transcript.isEmpty {
        messages.append(contentsOf: transcript)
      } else if let response = run.result?["response"].text, !response.isEmpty {
        messages.append(ChatMessage(role: "assistant", content: response))
      }
      return messages
    }
  }
}
