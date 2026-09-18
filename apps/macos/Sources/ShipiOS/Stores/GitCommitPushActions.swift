import Foundation

enum GitCommitPushAction { case commit, commitAndPush, push }

extension WorkspaceStore {
  @discardableResult func performGitAction(_ action: GitCommitPushAction,
    in workspace: DeveloperWorkspace, remote: String = "", destination: String = "",
    includeUnstaged: Bool = false, newBranch: String? = nil) async -> Bool {
    guard !workspace.gitActionRunning, !workspace.gitBusy, !workspace.generatingCommitMessage,
      !library.gitPreferences.readOnlyReview, let root = workspace.root else { return false }
    let token = UUID(), force = library.gitPreferences.alwaysForcePush
    workspace.gitActionToken = token
    workspace.gitActionRunning = true
    workspace.error = nil
    workspace.gitActionStatus = nil
    workspace.commitGenerationError = nil
    defer {
      if workspace.gitActionToken == token {
        workspace.gitActionRunning = false
        workspace.gitActionToken = nil
        workspace.gitActionPhase = ""
      }
    }
    func isCurrent() -> Bool {
      workspace.root == root && workspace.gitActionToken == token
        && !library.gitPreferences.readOnlyReview && !Task.isCancelled
    }
    if action != .push {
      do {
        workspace.gitActionPhase = "正在检查选中的变更…"
        let selection = try await GitCommitSelection.capture(at: root,
          includeUnstaged: includeUnstaged, newBranch: newBranch)
        guard isCurrent() else { return false }
        if workspace.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          workspace.gitActionPhase = "正在生成提交说明…"
          generateCommitMessage(in: workspace, includeUnstaged: includeUnstaged)
          await workspace.commitGenerationTask?.value
          guard workspace.commitGenerationError == nil,
            !workspace.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        }
        guard isCurrent() else { return false }
        workspace.gitActionPhase = newBranch == nil ? "正在准备提交…" : "正在创建分支…"
        workspace.gitBusy = true
        do { try await selection.apply() }
        catch {
          if workspace.gitActionToken == token { workspace.gitBusy = false }
          throw error
        }
        guard isCurrent() else {
          if workspace.gitActionToken == token { workspace.gitBusy = false }
          return false
        }
        workspace.gitBusy = false
        if let newBranch {
          workspace.gitBranch = newBranch
          workspace.gitActionStatus = "已创建分支 \(newBranch)"
        }
        workspace.gitActionPhase = "正在提交…"
        guard await workspace.commit(), isCurrent() else {
          if isCurrent() {
            let commitError = workspace.error
            await workspace.refreshGit()
            if isCurrent() { workspace.error = commitError }
          }
          return false
        }
        workspace.gitActionStatus = "已提交到 \(workspace.gitBranch)"
      } catch {
        if isCurrent() {
          let message = error.localizedDescription
          await workspace.refreshGit()
          if isCurrent() { workspace.error = message }
        }
        return false
      }
    }
    if action != .commit {
      guard isCurrent() else { return false }
      workspace.gitActionPhase = "正在推送…"
      guard await workspace.push(remote: remote, destination: destination, forceWithLease: force),
        isCurrent() else { return false }
    }
    return true
  }
}
