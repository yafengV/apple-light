import Foundation

extension DeveloperWorkspace {
  var reviewRepositoryFolder: URL? {
    reviewRepositories.first { $0.root.path == gitRepositoryRoot?.path }?.folder ?? root
  }

  var isPrimaryReviewRepository: Bool {
    if let selected = reviewRepositories.first(where: { $0.root.path == gitRepositoryRoot?.path }) {
      return selected.isPrimary
    }
    return selectedReviewRepository == nil
  }

  var canSelectReviewRepository: Bool {
    root != nil && reviewScope != .lastTurn && !gitBusy && !gitActionRunning && !generatingCommitMessage
  }

  func rememberReviewRepositoryDraft() {
    guard let path = gitRepositoryRoot?.path else { return }
    reviewRepositoryDrafts[path] = .init(message: commitMessage, commit: reviewCommit,
      branch: reviewBaseBranch, collapsed: collapsedReviewFiles)
  }

  func applyReviewRepositoryDraft(_ path: String) {
    let draft = reviewRepositoryDrafts[path]
    commitMessage = draft?.message ?? ""
    reviewCommit = draft?.commit ?? ""
    reviewBaseBranch = draft?.branch ?? ""
    collapsedReviewFiles = draft?.collapsed ?? []
  }

  @discardableResult func selectReviewRepository(_ path: String) async -> Bool {
    guard canSelectReviewRepository,
      reviewRepositories.contains(where: { entry in
        entry.id == path && fileRoots.contains { $0.path == entry.folder.path }
      }) else { return false }
    guard gitRepositoryRoot?.path != path else { return true }
    rememberReviewRepositoryDraft()
    selectedReviewRepository = path
    invalidateGitReviewContext()
    applyReviewRepositoryDraft(path)
    await refreshGit()
    return gitRepositoryRoot?.path == path && gitAvailable
  }

  /// Restored paths are hints; only an attached folder can establish a repository.
  func restoreReviewRepository(_ path: String?) {
    let requested = path.flatMap { value -> String? in
      guard value.hasPrefix("/"), !value.contains("\0") else { return nil }
      return GitBranchService.canonicalRoot(URL(fileURLWithPath: value)).path
    }
    let allowed = requested == nil || fileRoots.contains { folder in
      (try? GitRepositoryContext.candidate(at: folder))?.path == requested
    }
    let target = allowed ? requested : nil
    guard selectedReviewRepository != target else { return }
    rememberReviewRepositoryDraft()
    selectedReviewRepository = target
    invalidateGitReviewContext()
    if let target { applyReviewRepositoryDraft(target) }
    else if let repository = fileRoots.lazy.compactMap({ try? GitRepositoryContext.candidate(at: $0) }).first {
      applyReviewRepositoryDraft(repository.path)
    }
    scheduleGitRefresh()
  }
}
