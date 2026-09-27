import Foundation
import CryptoKit

enum SideChatCommand {
  static func prompt(in draft: String) -> String? {
    let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    if value == "/side" { return "" }
    guard value.hasPrefix("/side"), value.count > 5,
      value[value.index(value.startIndex, offsetBy: 5)].isWhitespace else { return nil }
    return String(value.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

extension WorkspaceStore {
  func canOpenSideChat(from taskID: String) -> Bool {
    libraryLoaded && !shuttingDown && !showingReviewMode
      && library.tasks.contains { $0.id == taskID && !$0.archived && !$0.isTransient }
  }

  @discardableResult func createSideChat(from taskID: String, prompt: String = "") throws -> WorkspaceTask {
    guard canOpenSideChat(from: taskID), let parent = library.tasks.first(where: { $0.id == taskID }) else {
      throw AgentFailure(message: "当前会话无法开启侧聊。")
    }
    let known = Dictionary((runs + library.localRuns).map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first })
    let sourceIDs = parent.runIDs.filter { known[$0]?.isActive == false }
    let now = Date()
    let side = WorkspaceTask(id: UUID().uuidString, project: parent.project,
      title: "侧聊 · \(parent.title)", runIDs: [], modelSelection: parent.modelSelection,
      sideChatParentID: parent.id, sideChatSourceRunIDs: sourceIDs,
      createdAt: now, updatedAt: now)
    var candidate = library
    candidate.tasks.insert(side, at: 0)
    candidate.drafts[side.id] = prompt
    try commitLibrary(candidate)
    return side
  }

  func closeSideChat(_ taskID: String) async {
    guard library.tasks.contains(where: { $0.id == taskID && $0.isSideChat }) else { return }
    if let active = activeChatRun(taskID: taskID), let job = modelTask(runID: active.id) {
      job.cancel()
      await job.value
    }
    await codexTransport.stop(taskID: taskID)
    guard let index = library.tasks.firstIndex(where: { $0.id == taskID && $0.isSideChat }) else { return }
    let side = library.tasks[index]
    do {
      var candidate = library
      candidate.tasks[index].archived = true
      try commitLibrary(candidate)
      if deleteArchivedTasks([taskID]) { removeSideChatCoreHome(side) }
    } catch { self.error = "无法关闭临时侧聊：\(error.localizedDescription)" }
  }

  func discardRestoredSideChats() {
    let sides = library.tasks.filter(\.isSideChat)
    let ids = Set(sides.map(\.id))
    guard !ids.isEmpty else { return }
    do {
      var candidate = library
      for index in candidate.tasks.indices where ids.contains(candidate.tasks[index].id) {
        candidate.tasks[index].archived = true
      }
      try commitLibrary(candidate)
      if deleteArchivedTasks(ids) {
        for side in sides { removeSideChatCoreHome(side) }
      }
    } catch { self.error = "无法清理上次的临时侧聊：\(error.localizedDescription)" }
  }

  private func removeSideChatCoreHome(_ side: WorkspaceTask) {
    guard let id = UUID(uuidString: side.id) else { return }
    let root = dataRoot.resolvingSymlinksInPath().standardizedFileURL
    let digest = SHA256.hash(data: Data(side.project.utf8))
      .map { String(format: "%02x", $0) }.joined()
    let home = root.appendingPathComponent(
      "Projects/\(digest)/Codex/Tasks/\(id.uuidString.lowercased())", isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL
    guard home.path.hasPrefix(root.path + "/Projects/\(digest)/Codex/Tasks/") else { return }
    try? FileManager.default.removeItem(at: home)
  }
}
