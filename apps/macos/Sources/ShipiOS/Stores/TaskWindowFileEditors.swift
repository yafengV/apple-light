import Foundation

/// A task window owns its file UI and editor resources, just as it owns its
/// browser and terminal resources. A tab ID alone is not a cross-window identity.
@MainActor final class TaskWindowFileEditors {
  private var workspaces: [WorkspaceContentTab: DeveloperWorkspace] = [:]
  var allWorkspaces: [DeveloperWorkspace] { Array(workspaces.values) }

  func workspace(for tab: WorkspaceContentTab, store: WorkspaceStore?, windowID: String) -> DeveloperWorkspace {
    let context = FileEditorRecoveryContext.file(tab, windowID: windowID)
    if let existing = workspaces[tab] {
      if existing.fileEditorRecoveryContext != context { store?.bindFileEditorRecovery(to: existing, context: context) }
      return existing
    }
    let workspace = DeveloperWorkspace()
    store?.bindFileEditorRecovery(to: workspace, context: context)
    workspaces[tab] = workspace
    return workspace
  }

  func existing(_ tab: WorkspaceContentTab) -> DeveloperWorkspace? { workspaces[tab] }

  func remove(owner: String, store: WorkspaceStore?) {
    for tab in Array(workspaces.keys) where tab.owner == owner {
      guard let workspace = workspaces.removeValue(forKey: tab) else { continue }
      store?.captureFileEditorRecovery(from: workspace)
      workspace.setProject(nil)
    }
  }

  func retain(_ owners: Set<String>, store: WorkspaceStore?) {
    for owner in Set(workspaces.keys.map(\.owner)) where !owners.contains(owner) {
      remove(owner: owner, store: store)
    }
  }

  func rekey(_ oldID: String, to replacement: WorkspaceContentTab?, store: WorkspaceStore?) {
    guard let old = workspaces.keys.first(where: { $0.id == oldID }),
      let workspace = workspaces.removeValue(forKey: old) else { return }
    if let replacement, replacement.kind == .file, workspaces[replacement] == nil {
      workspaces[replacement] = workspace
    } else {
      store?.captureFileEditorRecovery(from: workspace)
      workspace.setProject(nil)
    }
  }

  func shutdown(store: WorkspaceStore?) {
    for workspace in workspaces.values {
      store?.captureFileEditorRecovery(from: workspace)
      workspace.setProject(nil)
    }
    workspaces.removeAll()
  }
}
