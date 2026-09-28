import Foundation
import Observation

enum GitManagedBranchNext: Equatable { case commit, pullRequest(forceDraft: Bool) }

struct GitManagedBranchRequest: Identifiable {
  let id = UUID()
  let taskID: String
  let checkoutID: UUID
  let project: URL
  let root: URL
  let generation: UUID
  let epoch: UUID
  let next: GitManagedBranchNext?
}

@MainActor @Observable final class GitManagedBranchSetup {
  private(set) var request: GitManagedBranchRequest?
  private(set) var snapshot: GitBranchSnapshot?
  var name = ""
  private(set) var loading = false
  private(set) var validating = false
  private(set) var working = false
  private(set) var error: String?
  private(set) var validationError: String?
  private(set) var validatedInput: String?
  private(set) var succeeded = false
  @ObservationIgnored private var token = UUID()
  @ObservationIgnored private var validationToken = UUID()

  var canCreate: Bool {
    !loading && !working && !validating && snapshot?.currentCommit != nil
      && validatedInput == name && validationError == nil
  }
  func load(_ request: GitManagedBranchRequest, suggestion: String) async {
    let operation = UUID(); token = operation; self.request = request
    name = suggestion; snapshot = nil; loading = true; succeeded = false
    error = nil; validationError = nil; validatedInput = nil
    defer { if token == operation { loading = false } }
    do {
      let value = try await GitBranchService.snapshot(at: request.root)
      guard token == operation, !Task.isCancelled else { return }
      guard value.canChange, value.currentCommit != nil else { throw AgentFailure(message: "请先完成首次提交。") }
      snapshot = value
    } catch {
      if token == operation, !Task.isCancelled { self.error = error.localizedDescription }
    }
  }
  func validate() async {
    let operation = UUID(), input = name, root = request?.root, scope = token
    validationToken = operation; validatedInput = nil; validationError = nil; validating = true
    defer { if validationToken == operation { validating = false } }
    guard let root, !working else { return }
    do {
      try await Task.sleep(for: .milliseconds(200))
      _ = try await GitManagedBranchPlan.validate(input, at: root)
      guard token == scope, validationToken == operation, name == input, !Task.isCancelled else { return }
      validatedInput = input
    } catch {
      guard token == scope, validationToken == operation, name == input, !Task.isCancelled else { return }
      validationError = error.localizedDescription
    }
  }
  func cancel() {
    token = UUID(); validationToken = UUID(); loading = false; validating = false
    snapshot = nil; validatedInput = nil; succeeded = false; error = nil
    working = false; request = nil; name = ""; validationError = nil
  }
  func isCurrent(in workspace: DeveloperWorkspace, store: WorkspaceStore) -> Bool {
    guard let request, workspace.generationForGitMutation == request.generation,
      workspace.reviewRepositoryEpoch == request.epoch, workspace.root == request.project,
      workspace.gitRoot == request.root,
      let task = store.library.tasks.first(where: { $0.id == request.taskID }),
      GitBranchService.canonicalRoot(URL(fileURLWithPath: task.project)) == GitBranchService.canonicalRoot(request.project),
      let record = store.library.managedWorktree(forTaskID: request.taskID), record.ready,
      record.id == request.checkoutID,
      GitBranchService.canonicalRoot(URL(fileURLWithPath: record.path)) == GitBranchService.canonicalRoot(request.root) else { return false }
    return true
  }
  @discardableResult func create(in workspace: DeveloperWorkspace, store: WorkspaceStore) async -> Bool {
    guard canCreate, isCurrent(in: workspace, store: store), let request, let snapshot,
      !workspace.gitBusy, !workspace.gitActionRunning, workspace.canModifyReview,
      !store.library.gitPreferences.readOnlyReview else { return false }
    let operation = token, input = name
    working = true; error = nil
    workspace.gitBusy = true
    defer {
      if token == operation { working = false }
      if workspace.generationForGitMutation == request.generation, workspace.reviewRepositoryEpoch == request.epoch {
        workspace.gitBusy = false
      }
    }
    let authorizeRepository = workspace.gitMutationAuthorization(at: request.root)
    let authorize: GitMutationAuthorization = { [weak self] in
      try authorizeRepository()
      guard let self, self.token == operation, self.name == input,
        self.isCurrent(in: workspace, store: store), !store.library.gitPreferences.readOnlyReview else {
        throw CancellationError()
      }
    }
    var created = false, checkingOut = false, checkedOut = false
    do {
      guard let record = store.library.managedWorktree(forTaskID: request.taskID) else { throw CancellationError() }
      let common = try await WorktreeService.commonDirectory(at: request.root)
      let gitDirectory = try await GitReviewService.checked(["rev-parse", "--absolute-git-dir"], at: request.root)
        .trimmingCharacters(in: .newlines)
      guard common == GitBranchService.canonicalRoot(URL(fileURLWithPath: record.checkout.commonDirectory)),
        GitBranchService.canonicalRoot(URL(fileURLWithPath: gitDirectory)) != common,
        try await WorktreeService.registeredPaths(at: request.root).contains(GitBranchService.canonicalRoot(request.root).path) else {
        throw AgentFailure(message: "托管工作树登记已改变，请重新检查。")
      }
      let plan = try await GitManagedBranchPlan.capture(input, snapshot: snapshot)
      try await plan.create(authorize: authorize)
      created = true
      try authorize()
      var candidate = store.library
      guard let index = candidate.managedWorktrees.firstIndex(where: { $0.id == request.checkoutID }) else { throw CancellationError() }
      candidate.managedWorktrees[index].syncedBranch = .init(reference: "refs/heads/" + plan.name, tree: plan.tree)
      try store.commitLibrary(candidate)
      checkingOut = true
      try await plan.checkout(authorize: authorize)
      checkedOut = true
      try authorize()
      let current = try await GitBranchService.snapshot(at: request.root)
      guard current.currentReference == "refs/heads/" + plan.name,
        current.currentCommit == plan.snapshot.currentCommit else {
        throw AgentFailure(message: "检出后的分支或提交已改变，请重新检查。")
      }
      try authorize()
      candidate = store.library
      guard let taskIndex = candidate.tasks.firstIndex(where: { $0.id == request.taskID }) else { throw CancellationError() }
      candidate.tasks[taskIndex].gitBranch = plan.name
      try store.commitLibrary(candidate)
      guard token == operation else { return false }
      succeeded = true
      workspace.gitActionStatus = "已创建并检出分支 " + plan.name
      workspace.gitBusy = false
      await workspace.refreshGit()
      guard token == operation, isCurrent(in: workspace, store: store) else { return false }
      workspace.showingManagedBranchSetup = false
      return true
    } catch {
      guard token == operation, !(error is CancellationError) else { return false }
      let title = checkedOut ? "保存任务分支失败" : checkingOut ? "检出分支失败" : "设置分支失败"
      self.error = (checkedOut ? "分支已创建并检出，未继续原操作，请检查后再继续。\n"
        : created ? "分支已创建，请检查后再继续。\n" : "") + error.localizedDescription
      store.notices.show(id: "branch-setup-" + request.id.uuidString, title: title, level: .error, taskID: request.taskID)
      validatedInput = nil
      return false
    }
  }
}

extension WorkspaceStore {
  /// The reference review toolbar shows only Create branch for a managed,
  /// named default branch. Detached HEAD keeps the commit/PR action rows.
  func showsManagedBranchToolbar(in workspace: DeveloperWorkspace, taskID: String?) -> Bool {
    guard managedCheckout(in: workspace, taskID: taskID) != nil,
      let request = workspace.gitCommands.request, request.primary,
      request.repository.taskID == taskID, request.repository.root == workspace.gitRoot,
      request.repository.generation == workspace.generationForGitMutation,
      request.repository.epoch == workspace.reviewRepositoryEpoch,
      request.repository.revision == workspace.reviewSnapshot,
      let value = workspace.gitCommands.snapshot, let branch = value.branchName else { return false }
    return branch == value.defaultBranch
  }
  func managedCheckout(in workspace: DeveloperWorkspace, taskID: String?) -> ManagedWorktree? {
    guard let taskID, let project = workspace.root, workspace.isPrimaryReviewRepository,
      let task = library.tasks.first(where: { $0.id == taskID }),
      GitBranchService.canonicalRoot(URL(fileURLWithPath: task.project)) == GitBranchService.canonicalRoot(project),
      let record = library.managedWorktree(forTaskID: taskID), record.ready,
      GitBranchService.canonicalRoot(URL(fileURLWithPath: record.path)) == workspace.gitRoot.map(GitBranchService.canonicalRoot) else { return nil }
    return record
  }
  @discardableResult func presentManagedBranchSetup(in workspace: DeveloperWorkspace,
    taskID: String?, next: GitManagedBranchNext? = nil) -> Bool {
    guard let taskID, let record = managedCheckout(in: workspace, taskID: taskID),
      let project = workspace.root, let root = workspace.gitRoot,
      workspace.gitAvailable, workspace.canModifyReview, !library.gitPreferences.readOnlyReview,
      !workspace.gitBusy, !workspace.gitActionRunning, !workspace.showingManagedBranchSetup,
      !workspace.showingCommitPush, !workspace.showingPullRequest else { return false }
    workspace.managedBranchRequest = .init(taskID: taskID, checkoutID: record.id, project: project, root: root,
      generation: workspace.generationForGitMutation, epoch: workspace.reviewRepositoryEpoch, next: next)
    workspace.showingManagedBranchSetup = true
    return true
  }
  func finishManagedBranchPresentation(in workspace: DeveloperWorkspace) {
    guard !workspace.showingManagedBranchSetup else { return }
    let setup = workspace.managedBranchSetup
    if setup.succeeded, setup.isCurrent(in: workspace, store: self),
      let request = setup.request, workspace.managedBranchRequest?.id == request.id,
      !workspace.gitBusy, !workspace.gitActionRunning, workspace.canModifyReview,
      !library.gitPreferences.readOnlyReview {
      switch request.next {
      case .commit: workspace.presentGitOptions(taskID: request.taskID, pullRequest: false)
      case .pullRequest(let draft): workspace.presentGitOptions(taskID: request.taskID, pullRequest: true, forceDraft: draft)
      case nil: break
      }
    }
    workspace.managedBranchRequest = nil; setup.cancel()
  }
}
