import Foundation

enum PinnedBrowserForkDestination: String, CaseIterable {
  case currentWorkspace = "fork-browser-tab-into-current-workspace"
  case newWorktree = "fork-browser-tab-into-new-worktree"
}

extension WorkspaceStore {
  func pinnedBrowserForkDestinations(_ context: PinnedBrowserActionContext) -> [PinnedBrowserForkDestination] {
    guard pinnedBrowserActionIsCurrent(context), canForkTaskFromMenu(context.pin.owner) else { return [] }
    var result: [PinnedBrowserForkDestination] = [.currentWorkspace]
    if canForkTaskToNewWorktree(context.pin.owner) { result.append(.newWorktree) }
    return result
  }

  func pinnedBrowserForkTitle(_ destination: PinnedBrowserForkDestination,
    context: PinnedBrowserActionContext) -> String {
    if destination == .newWorktree { return "在新工作树中创建聊天分支" }
    guard let task = library.tasks.first(where: { $0.id == context.pin.owner }) else { return "创建聊天分支" }
    return taskForkUsesWorktree(task) ? "在同一工作树中创建聊天分支" : "创建聊天分支"
  }

  /// The menu belongs to the live browser source, even when another chat is displayed.
  /// Both routes preserve Core's native fork origin and use the shared persisted fork lifecycle.
  @discardableResult func forkPinnedBrowser(_ context: PinnedBrowserActionContext,
    to destination: PinnedBrowserForkDestination) async -> WorkspaceTask? {
    guard pinnedBrowserForkDestinations(context).contains(destination) else { return nil }
    switch destination {
    case .currentWorkspace: return await forkTaskFromMenu(context.pin.owner)
    case .newWorktree: return await forkTaskToNewWorktree(context.pin.owner)
    }
  }
}
