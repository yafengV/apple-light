import AppKit

extension WorkspaceStore {
  var worktreeRoot: URL {
    GitBranchService.canonicalRoot(library.worktreeRoot.map { URL(fileURLWithPath: $0) }
      ?? dataRoot.appendingPathComponent("worktrees", isDirectory: true))
  }

  func beginWorktreeCreation(from path: String) {
    guard libraryLoaded, !busy, activeLocalRun == nil, library.projects.contains(path) else { return }
    worktreeSource = path
    worktreeError = nil
    setOverlay(.worktreeCreation, presented: true)
  }

  func setWorktreeRoot(_ url: URL?) {
    guard libraryLoaded, !busy else { return }
    do {
      var candidate = library
      candidate.worktreeRoot = url.map { GitBranchService.canonicalRoot($0).path }
      try commitLibrary(candidate)
      worktreeError = nil
    } catch { worktreeError = error.localizedDescription }
  }

  func chooseWorktreeRoot() {
    guard !busy, let window = NSApp.keyWindow else { return }
    let panel = NSOpenPanel()
    panel.title = "选择工作树根目录"
    panel.canChooseFiles = false; panel.canChooseDirectories = true
    panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
    panel.directoryURL = worktreeRoot
    panel.beginSheetModal(for: window) { [weak self] response in
      if response == .OK, let url = panel.url {
        Task { @MainActor in self?.setWorktreeRoot(url) }
      }
    }
  }

  @discardableResult func createPermanentWorktree(snapshot: GitBranchSnapshot,
    branch: GitBranchChoice?, title: String) async -> PermanentWorktree? {
    guard libraryLoaded, !busy, activeLocalRun == nil,
      library.projects.contains(where: { GitBranchService.canonicalRoot(URL(fileURLWithPath: $0)) == snapshot.root }) else {
      worktreeError = "请等待当前任务完成，并从已添加的项目创建工作树。"
      return nil
    }
    busy = true; worktreeError = nil
    defer { busy = false }
    do {
      let record = try await WorktreeService.plan(snapshot: snapshot, branch: branch, title: title, parent: worktreeRoot)
      var candidate = library
      candidate.permanentWorktrees.append(record)
      // If this write fails no Git command creating a worktree has run yet.
      try commitLibrary(candidate)
      return try await finishWorktree(record)
    } catch {
      worktreeError = error.localizedDescription
      return nil
    }
  }

  @discardableResult func recoverWorktree(_ id: UUID) async -> PermanentWorktree? {
    guard libraryLoaded, !busy, activeLocalRun == nil,
      let record = library.permanentWorktrees.first(where: { $0.id == id && !$0.ready }) else { return nil }
    busy = true; worktreeError = nil
    defer { busy = false }
    do { return try await finishWorktree(record) }
    catch { worktreeError = error.localizedDescription; return nil }
  }

  private func finishWorktree(_ record: PermanentWorktree) async throws -> PermanentWorktree {
    try await WorktreeService.createOrRecover(record)
    var ready = PermanentWorktree(id: record.id, source: record.source,
      path: GitBranchService.canonicalRoot(URL(fileURLWithPath: record.path)).path,
      commonDirectory: GitBranchService.canonicalRoot(URL(fileURLWithPath: record.commonDirectory)).path,
      startingCommit: record.startingCommit, startingName: record.startingName,
      createdAt: record.createdAt, title: record.title)
    ready.ready = true
    var candidate = library
    candidate.permanentWorktrees.removeAll { $0.id == ready.id }
    candidate.permanentWorktrees.append(ready)
    candidate.visit(ready.path)
    candidate.projectNames[ready.path] = ready.title
    if let profile = library.profiles[ready.source] { candidate.profiles[ready.path] = profile }
    do { try commitLibrary(candidate) }
    catch { throw AgentFailure(message: "工作树已创建，但项目登记未保存。请在设置 → 工作树中恢复登记。路径：\(ready.path)\n\(error.localizedDescription)") }
    return ready
  }

  func openPermanentWorktree(_ record: PermanentWorktree) async {
    guard record.ready, !busy, activeLocalRun == nil else { return }
    presentedOverlay = nil
    recordNavigation()
    await open(URL(fileURLWithPath: record.path))
  }
}
