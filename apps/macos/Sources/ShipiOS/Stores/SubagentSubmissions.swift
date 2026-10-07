import Foundation

extension WorkspaceStore {
  func subagentSubmissions(taskID: String, rootThreadID: String, childThreadID: String) -> [SubagentSubmission] {
    library.subagentSubmissions.filter {
      $0.taskID == taskID && $0.rootThreadID == rootThreadID && $0.childThreadID == childThreadID
    }
  }

  func recordSubagentSubmission(_ record: SubagentSubmission) throws {
    guard libraryLoaded, !shuttingDown else { throw AgentFailure(message: "工作区尚未就绪或正在关闭。") }
    var candidate = library
    if let index = candidate.subagentSubmissions.firstIndex(where: { $0.id == record.id }) {
      let old = candidate.subagentSubmissions[index]
      guard old.taskID == record.taskID, old.rootThreadID == record.rootThreadID,
        old.childThreadID == record.childThreadID, old.message == record.message,
        old.wireDigest == record.wireDigest, old.wireByteCount == record.wireByteCount,
        old.expectedTurnID == record.expectedTurnID, old.phase == .pending,
        record.phase != .pending else { throw AgentFailure(message: "子任务附件记录已失效。") }
      candidate.subagentSubmissions[index] = record
    } else {
      guard record.phase == .pending,
        let task = candidate.tasks.first(where: { $0.id == record.taskID }),
        task.codexThreadID == record.rootThreadID,
        subagents(taskID: task.id).contains(where: {
          $0.rootThreadID == record.rootThreadID && $0.threadID == record.childThreadID && $0.acceptsInput
        }) else { throw AgentFailure(message: "子任务所属会话已变化，输入未发送。") }
      candidate.subagentSubmissions.append(record)
    }
    do { try commitLibrary(candidate) }
    catch {
      self.error = "无法保存子任务附件记录：\(error.localizedDescription)"
      // The pending record was already saved before submission. After an ACK,
      // retain accurate in-memory metadata without reporting the send as failed.
      if record.phase != .pending { library = candidate }
      throw error
    }
  }
}
