import Foundation

extension WorkspaceStore {
  private func codexHookRunID(taskID: String, threadID: String, event: JSONValue) -> String? {
    guard let task = library.tasks.first(where: { $0.id == taskID }) else { return nil }
    let name = event["run"]["event_name"].text
    let lifecycle = event["run"]["scope"].text == "thread"
      && ["session_start", "session_end"].contains(name ?? "")
    let ending = lifecycle && name == "session_end"
    // A closing session has its own internal turn ID. Bind it to the last
    // historical run of that thread, never a pending run for a new service.
    guard task.codexThreadID == threadID || ending else { return nil }
    return task.runIDs.last { id in
      guard let run = library.chatRuns.first(where: { $0.id == id }) else { return false }
      let turnID = event["turn_id"].text
      let bound = run.result?["codex_thread_id"].text == threadID
      return (bound || (!ending && turnID == nil && run.isActive))
        && (ending || turnID == nil || run.result?["codex_turn_id"].text == turnID
          || (lifecycle && name == "session_start" && run.isActive))
    }
  }

  /// Match late asynchronous completions to their exact historical turn, even
  /// after its response stream finished or another turn started.
  func recordCodexHook(taskID: String, threadID: String?, event: JSONValue) {
    guard let threadID, let runID = codexHookRunID(taskID: taskID, threadID: threadID, event: event) else { return }
    recordCodexHook(runID: runID, taskID: taskID, threadID: threadID, event: event)
  }

  func recordCodexHook(runID: String, taskID: String, threadID: String, event: JSONValue) {
    guard ["hook_started", "hook_completed"].contains(event["type"].text ?? ""),
      codexHookRunID(taskID: taskID, threadID: threadID, event: event) == runID,
      let index = library.chatRuns.firstIndex(where: { $0.id == runID }),
      let data = try? JSONEncoder().encode(event["run"]),
      var hook = try? JSONDecoder().decode(CodexHookRun.self, from: data), !hook.id.isEmpty else { return }
    hook.runtimeTurnID = event["turn_id"].text
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
