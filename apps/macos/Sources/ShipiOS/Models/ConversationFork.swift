import Foundation

struct ConversationForkOrigin: Codable, Equatable {
  let taskID: String
  let runID: String
}

struct CodexForkOrigin: Codable, Equatable {
  let taskID: String
  let workspace: String
  let threadID: String
  let throughTurnID: String

  var wireValue: JSONValue {
    .object(["taskId": .string(taskID), "workspace": .string(workspace),
      "threadId": .string(threadID), "throughTurnId": .string(throughTurnID)])
  }
}

extension WorkspaceLibrary {
  /// Snapshot history into distinct records: a run ID must belong to one task.
  mutating func forkConversation(
    taskID: String, through runID: String? = nil, availableRuns: [AgentRun]
  ) throws -> WorkspaceTask {
    guard let source = tasks.first(where: { $0.id == taskID }) else {
      throw AgentFailure(message: "找不到要分叉的任务。")
    }
    let history = try forkHistory(taskID: taskID, through: runID, availableRuns: availableRuns)
    let ids = history.map(\.id)
    var snapshots: [AgentRun] = []
    var origins: [String: String] = [:]
    var copiedNotes: [String: String] = [:]
    var copiedBranches: [String: String] = [:]
    var copiedFiles: [String: [FileAttachment]] = [:]
    var copiedImages: [String: [ImageAttachment]] = [:]
    for run in history {
      let id = run.id
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
    var fork = WorkspaceTask(
      id: UUID().uuidString, project: source.project,
      title: String(source.title.prefix(112)) + " · 分叉", runIDs: snapshots.map(\.id),
      forkOrigin: ConversationForkOrigin(taskID: source.id, runID: ids.last!), modelSelection: source.modelSelection, createdAt: now, updatedAt: now)
    if let lastChat = history.last(where: { $0.kind == "chat" }),
      let throughTurnID = lastChat.result?["codex_turn_id"].text,
      let threadID = lastChat.result?["codex_thread_id"].text,
      (source.codexThreadID == threadID || source.codexForkOrigin != nil),
      let actualThread = source.codexThreadID, let workspace = source.codexWorkspacePath {
      fork.codexForkOrigin = CodexForkOrigin(taskID: source.id, workspace: workspace,
        threadID: actualThread, throughTurnID: throughTurnID)
    } else if source.codexThreadID == nil, let origin = source.codexForkOrigin,
      let lastChat = history.last(where: { $0.kind == "chat" }),
      lastChat.result?["codex_thread_id"].text != nil,
      let turnID = lastChat.result?["codex_turn_id"].text {
      // Inherited turns may name a grandparent thread. The native rollout still contains their IDs;
      // the Agent validates the chosen boundary instead of silently switching to text replay.
      fork.codexForkOrigin = CodexForkOrigin(taskID: origin.taskID, workspace: origin.workspace,
        threadID: origin.threadID, throughTurnID: turnID)
    }
    tasks.insert(fork, at: 0)
    forkRuns.append(contentsOf: snapshots)
    forkRunOrigins.merge(origins) { _, new in new }
    notes.merge(copiedNotes) { _, new in new }
    runBranches.merge(copiedBranches) { _, new in new }
    runImages.merge(copiedImages) { _, new in new }
    runFiles.merge(copiedFiles) { _, new in new }
    return fork
  }

  /// Resolve the complete source prefix before any new task or run is created.
  func forkHistory(taskID: String, through runID: String? = nil, availableRuns: [AgentRun]) throws -> [AgentRun] {
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
    let available = Dictionary(availableRuns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var historyProjects: Set<String> = [source.project]
    if let checkout = managedWorktree(forTaskID: taskID),
      source.project == checkout.source || source.project == checkout.path {
      // Handoff changes the task's current directory, not where its past executions ran.
      historyProjects.formUnion([checkout.source, checkout.path])
    }
    return try ids.map { id in
      // Copied fork records retain their real execution directories even when the child
      // stays local and does not own the source's managed checkout.
      let inheritedProject = source.forkOrigin == nil ? nil : forkRuns.first { $0.id == id }?.project
      guard let run = available[id], !run.isActive,
        historyProjects.contains(run.project) || inheritedProject == run.project else {
        throw AgentFailure(message: "历史尚未完整加载或包含进行中的回合，无法分叉。")
      }
      return run
    }
  }

  func chatContext(taskID: String?) -> [ChatMessage] {
    let task = tasks.first(where: { $0.id == taskID })
    let ids = (task?.sideChatSourceRunIDs ?? []) + (task?.runIDs ?? [])
    let stored = Dictionary(localRuns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return ids.flatMap { id -> [ChatMessage] in
      guard let run = stored[id], run.kind == "chat",
        run.request["conversation_kind"].text != "compact" else { return [] }
      var messages = [ChatMessage(role: "user", content: notes[id] ?? "", images: runImages[id] ?? [], files: runFiles[id] ?? [])]
      if !run.codexSteeredMessages.isEmpty, let items = run.responseItems {
        for item in items {
          switch item {
          case .message(_, let text) where !text.isEmpty:
            messages.append(ChatMessage(role: "assistant", content: text))
          case .user(let messageID):
            if let message = run.codexSteeredMessages.first(where: { $0.id == messageID }) {
              messages.append(ChatMessage(role: "user", content: message.text,
                images: message.images, files: message.files))
            }
          default: break
          }
        }
        return messages
      }
      if let transcript = try? run.result?["tool_messages"].decode([ChatMessage].self), !transcript.isEmpty {
        messages.append(contentsOf: transcript)
      } else if let response = run.result?["response"].text, !response.isEmpty {
        messages.append(ChatMessage(role: "assistant", content: response))
      }
      return messages
    }
  }
}
