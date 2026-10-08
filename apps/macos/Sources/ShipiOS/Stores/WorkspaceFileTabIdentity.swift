import Foundation

extension WorkspaceStore {
  func validatedWorkspaceFileRoot(_ path: String) -> URL? {
    guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
    return GitBranchService.canonicalRoot(URL(fileURLWithPath: path, isDirectory: true))
  }

  func workspaceFileTabRoot(_ tab: WorkspaceContentTab, savedRoot: String? = nil) -> URL? {
    guard tab.kind == .file else { return nil }
    if let savedRoot { return validatedWorkspaceFileRoot(savedRoot) }
    if let root = workspaceFileTabRoots[tab.id] { return root }
    if let saved = library.workspaceTabLayouts[tab.owner]?.tabs.first(where: { $0.id == tab.id }),
      let root = saved.fileRoot { return validatedWorkspaceFileRoot(root) }
    if let pin = library.pinnedContentTabs.first(where: { $0.sourceTabID == tab.id && $0.kind == .file }),
      let root = pin.fileRoot { return validatedWorkspaceFileRoot(root) }
    if let root = fileTabWorkspaces[tab.id]?.root { return root }
    return workspaceTabProject(owner: tab.owner)
  }

  func workspaceFileTabURL(_ tab: WorkspaceContentTab) -> URL? {
    guard case .file(let path, _) = tab, !path.isEmpty,
      let root = workspaceFileTabRoot(tab) else { return nil }
    return (try? WorkspaceFileScope.location(path,
      roots: [root] + additionalWorkspaceFolders(for: root)))?.url
  }

  /// Prepare durable roots against the old project configuration. Applying the
  /// runtime cache happens only after the project edit successfully saves.
  func preserveWorkspaceFileTabRoots(in candidate: inout WorkspaceLibrary) -> [String: URL] {
    var roots: [String: URL] = [:]
    for tab in workspaceTabs + closedWorkspaceTabs where tab.kind == .file {
      roots[tab.id] = workspaceFileTabRoot(tab)
    }
    if workspaceLayoutActiveOwner == currentWorkspaceTabOwner,
      automationsLoaded || library.workspaceTabLayouts[currentWorkspaceTabOwner]?.tabs.contains(where: { $0.kind == .pullRequestWatch }) != true {
      candidate.workspaceTabLayouts[currentWorkspaceTabOwner] = workspaceTabLayoutSnapshot
    }
    for owner in Array(candidate.workspaceTabLayouts.keys) {
      guard var layout = candidate.workspaceTabLayouts[owner] else { continue }
      for index in layout.tabs.indices where layout.tabs[index].kind == .file && layout.tabs[index].fileRoot == nil {
        let saved = layout.tabs[index]
        layout.tabs[index].fileRoot = (roots[saved.id] ?? workspaceTabProject(owner: owner))?.path
      }
      candidate.workspaceTabLayouts[owner] = layout
    }
    for index in candidate.pinnedContentTabs.indices where candidate.pinnedContentTabs[index].kind == .file
      && candidate.pinnedContentTabs[index].fileRoot == nil {
      let pin = candidate.pinnedContentTabs[index]
      let saved = candidate.workspaceTabLayouts[pin.owner]?.tabs.first { $0.id == pin.sourceTabID }
      candidate.pinnedContentTabs[index].fileRoot = roots[pin.sourceTabID]?.path
        ?? saved?.fileRoot ?? workspaceTabProject(owner: pin.owner)?.path
    }
    return roots
  }
}
