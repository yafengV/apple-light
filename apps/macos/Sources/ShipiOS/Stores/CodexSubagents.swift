import Foundation

extension WorkspaceStore {
  @discardableResult func openSubagents(taskID: String? = nil, in placement: WorkspaceTabPlacement = .right) -> Bool {
    let owner = taskID ?? currentWorkspaceTabOwner
    guard owner == currentWorkspaceTabOwner, placement != .bottom,
      library.tasks.contains(where: { $0.id == owner }) else { return false }
    let tab = WorkspaceContentTab.subagents(owner: owner)
    if !workspaceTabs.contains(tab) { workspaceTabs.append(tab); workspaceTabPlacements[tab.id] = placement }
    activateWorkspaceTab(tab.id)
    return true
  }
  func subagents(taskID: String) -> [CodexSubagent] {
    library.tasks.first { $0.id == taskID }?.codexSubagents ?? []
  }

  func activeSubagents(taskID: String) -> [CodexSubagent] {
    guard let root = library.tasks.first(where: { $0.id == taskID })?.codexThreadID else { return [] }
    return subagents(taskID: taskID).filter { $0.rootThreadID == root && $0.working }
  }

  func recordSubagentSnapshot(taskID: String, threadID: String?, event: JSONValue) {
    guard let threadID, let index = library.tasks.firstIndex(where: { $0.id == taskID }),
      library.tasks[index].codexThreadID == threadID else { return }
    var assembler = subagentSnapshotAssemblers[taskID] ?? .init()
    let snapshot = assembler.append(event, root: threadID)
    subagentSnapshotAssemblers[taskID] = assembler
    guard let snapshot else { return }
    guard let version = assembler.completedRevision,
      version > (subagentSnapshotRevisions[taskID] ?? 0) else { return }
    subagentSnapshotRevisions[taskID] = version
    let previous = library.tasks[index].codexSubagents ?? []
    var next = previous.filter { $0.rootThreadID != threadID }.map { entry in
      var entry = entry; entry.disconnect(); return entry
    }
    for var row in snapshot {
      if let old = previous.first(where: { $0.id == row.id }), !row.loaded {
        row.parentThreadID = row.parentThreadID ?? old.parentThreadID
        row.nickname = row.nickname ?? old.nickname; row.role = row.role ?? old.role
        row.depth = row.depth ?? old.depth; row.model = row.model ?? old.model
        row.reasoningEffort = row.reasoningEffort ?? old.reasoningEffort
        row.preview = row.preview ?? old.preview
        if !old.status.working { row.status = old.status }
      }
      next.append(row)
    }
    guard next != previous else { return }
    library.tasks[index].codexSubagents = next
    saveLibrary()
  }

  func disconnectSubagents(taskID: String) {
    subagentSnapshotAssemblers.removeValue(forKey: taskID)
    subagentSnapshotRevisions.removeValue(forKey: taskID)
    guard let index = library.tasks.firstIndex(where: { $0.id == taskID }),
      var rows = library.tasks[index].codexSubagents else { return }
    let before = rows
    for i in rows.indices { rows[i].disconnect() }
    guard before != rows else { return }
    library.tasks[index].codexSubagents = rows
    saveLibrary()
  }
}
