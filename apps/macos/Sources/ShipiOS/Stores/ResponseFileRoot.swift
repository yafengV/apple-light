import Foundation

extension WorkspaceStore {
  /// Review paths belong to the saved diff; ordinary replies belong to the run's cwd.
  func responseFileRoot(for run: AgentRun) -> URL? {
    guard run.request["conversation_kind"].text == "review" else { return workspaceRoot(for: run) }
    guard let cwd = workspaceRoot(for: run) else { return nil }
    let root: URL
    var cacheRoot = false
    if let path = run.request["review_repository_root"].text {
      guard path.hasPrefix("/") else { return nil }
      root = URL(fileURLWithPath: path, isDirectory: true)
    } else if let saved = legacyReviewFileRoots[run.id] {
      root = saved
    } else {
      // Older reviews already have this base in their private immutable snapshot.
      // Cache successful reads so rendering a reply does not repeatedly parse its diff.
      guard let snapshot = try? ReviewSnapshotStorage.load(runID: run.id, root: dataRoot) else { return nil }
      guard let path = snapshot.repositoryRoot, path.hasPrefix("/") else { return nil }
      root = URL(fileURLWithPath: path, isDirectory: true)
      cacheRoot = true
    }
    let base = GitBranchService.canonicalRoot(root).path
    let project = GitBranchService.canonicalRoot(cwd).path
    let attached = run.request["additional_folders"].items.compactMap(\.text)
    guard project == base || project.hasPrefix(base + "/") || attached.contains(where: { path in
      guard path.hasPrefix("/"), !path.contains("\0") else { return false }
      let folder = GitBranchService.canonicalRoot(URL(fileURLWithPath: path)).path
      return folder == base || folder.hasPrefix(base + "/")
    }) else { return nil }
    if cacheRoot { legacyReviewFileRoots[run.id] = root }
    return root
  }
}
