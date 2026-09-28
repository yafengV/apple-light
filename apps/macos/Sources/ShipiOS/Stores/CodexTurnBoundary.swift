import Foundation

extension WorkspaceStore {
  /// Keep the runtime turn identity with its UI run so historical forks have an exact boundary.
  func recordCodexTurnBoundary(runID: String, taskID: String, event: JSONValue) {
    guard let turnID = event["turn_id"].text, !turnID.isEmpty,
      let task = library.tasks.first(where: { $0.id == taskID }),
      task.runIDs.contains(runID), let threadID = task.codexThreadID,
      let index = library.chatRuns.firstIndex(where: { $0.id == runID }) else { return }
    let current = library.chatRuns[index]
    var result: [String: JSONValue] = [:]
    if case .object(let fields) = current.result { result = fields }
    result["codex_turn_id"] = .string(turnID)
    result["codex_thread_id"] = .string(threadID)
    let updated = AgentRun(id: current.id, kind: current.kind, project: current.project,
      status: current.status, createdAt: current.createdAt, updatedAt: current.updatedAt,
      request: current.request, result: .object(result))
    library.chatRuns[index] = updated
    if let visible = runs.firstIndex(where: { $0.id == runID }) { runs[visible] = updated }
  }
}
