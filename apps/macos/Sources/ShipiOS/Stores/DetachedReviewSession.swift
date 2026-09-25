import Foundation
import Observation

@MainActor @Observable final class DetachedReviewSession {
  let workspace = DeveloperWorkspace()
  private(set) var owner: String?

  func configure(store: WorkspaceStore, owner: String) {
    let root = store.workspaceTabProject(owner: owner)
    guard self.owner != owner || workspace.root != root else { return }
    self.owner = owner
    workspace.setProject(root)
    workspace.reviewScope = store.currentWorkspaceTabOwner == owner
      ? store.workspace.reviewScope
      : store.library.workspaceTabLayouts[owner]?.reviewScope ?? store.library.gitPreferences.defaultReviewScope
  }

  func saveScope(store: WorkspaceStore) {
    guard let owner, workspace.root != nil,
      workspace.root == store.workspaceTabProject(owner: owner),
      store.workspaceTabs.contains(.review(owner: owner)) else { return }
    if store.currentWorkspaceTabOwner == owner { store.workspace.reviewScope = workspace.reviewScope }
    store.library.workspaceTabLayouts[owner]?.reviewScope = workspace.reviewScope
    store.saveLibrary()
  }

  func shutdown() { workspace.setProject(nil) }
}

extension WorkspaceStore {
  func workspaceTabProject(owner: String) -> URL? {
    let path: String?
    if owner.hasPrefix("new:") {
      path = owner == "new:none" ? nil : String(owner.dropFirst(4))
    } else {
      path = library.tasks.first { $0.id == owner }?.project
    }
    guard let path, !path.isEmpty else { return nil }
    return GitBranchService.canonicalRoot(URL(fileURLWithPath: path))
  }
}
