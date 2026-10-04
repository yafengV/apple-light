import Foundation

extension WorkspaceStore {
  /// Match late asynchronous completions to their exact historical turn, even
  /// after its response stream finished or another turn started.
  func recordCodexHook(taskID: String, threadID: String?, event: JSONValue) {
    guard let task = library.tasks.first(where: { $0.id == taskID }),
      let threadID, task.codexThreadID == threadID,
      let runID = task.runIDs.last(where: { id in
        guard let run = library.chatRuns.first(where: { $0.id == id }) else { return false }
        let turnID = event["turn_id"].text
        return (run.result?["codex_thread_id"].text == threadID || (turnID == nil && run.isActive))
          && (turnID == nil || run.result?["codex_turn_id"].text == turnID)
      }) else { return }
    recordCodexHook(runID: runID, taskID: taskID, threadID: threadID, event: event)
  }

  func recordCodexHook(runID: String, taskID: String, threadID: String, event: JSONValue) {
    guard ["hook_started", "hook_completed"].contains(event["type"].text ?? ""),
      let task = library.tasks.first(where: { $0.id == taskID }), task.runIDs.contains(runID),
      task.codexThreadID == threadID,
      let index = library.chatRuns.firstIndex(where: { $0.id == runID }),
      (event["turn_id"].text == nil || library.chatRuns[index].result?["codex_turn_id"].text == event["turn_id"].text),
      let data = try? JSONEncoder().encode(event["run"]),
      var hook = try? JSONDecoder().decode(CodexHookRun.self, from: data), !hook.id.isEmpty else { return }
    let current = library.chatRuns[index]
    var hooks = current.codexHookRuns
    if let existing = hooks.lastIndex(where: {
      $0.hookID == hook.hookID && ($0.status == "running"
        || (hook.completedAt != nil && $0.completedAt == hook.completedAt)
        || (hook.status == "running" && $0.startedAt == hook.startedAt))
    }) {
      hook.invocationID = hooks[existing].id
      if hooks[existing] == hook { return }
      // Delayed start notifications must never revert a completed invocation.
      if hooks[existing].status != "running", hook.status == "running" { return }
      hooks[existing] = hook
    } else {
      let count = hooks.filter { $0.hookID == hook.hookID }.count
      hook.invocationID = count == 0 ? hook.hookID : "\(hook.hookID):\(count)"
      hooks.append(hook)
    }
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(hooks)) else { return }
    var result: [String: JSONValue] = [:]
    if case .object(let fields) = current.result { result = fields }
    result["codex_hook_runs"] = value
    let updated = AgentRun(id: current.id, kind: current.kind, project: current.project,
      status: current.status, createdAt: current.createdAt, updatedAt: current.updatedAt,
      request: current.request, result: .object(result))
    library.chatRuns[index] = updated
    if let visible = runs.firstIndex(where: { $0.id == runID }) { runs[visible] = updated }
    saveLibrary()
  }
}
