import Foundation

extension WorkspaceStore {
  func presentCodeReviewMode() {
    guard destination == .workspace, let project else {
      error = "请先打开 Git 项目。"
      return
    }
    showingReviewMode = true
    reviewModeProject = project.path
    reviewModeBranches = []
    reviewModeError = nil
    focusComposer = UUID()
    Task { await loadCodeReviewBranches() }
  }

  func dismissCodeReviewMode() {
    showingReviewMode = false
    reviewModeProject = nil
    reviewModeBranches = []
    reviewModeLoading = false
    reviewModeStarting = false
    reviewModeError = nil
  }

  func loadCodeReviewBranches() async {
    guard showingReviewMode, let root = project, reviewModeProject == root.path else { return }
    reviewModeLoading = true
    reviewModeError = nil
    let epoch = workspace.reviewRepositoryEpoch
    defer { if showingReviewMode, project?.path == root.path { reviewModeLoading = false } }
    do {
      let repository = workspace.gitRoot ?? root
      let choices = try await GitReviewService.branches(at: repository)
      guard showingReviewMode, project?.path == root.path, reviewModeProject == root.path,
        workspace.reviewRepositoryEpoch == epoch else {
        return
      }
      let current = workspace.gitBranch
      reviewModeBranches = choices.filter {
        $0.title != current && $0.id != "refs/heads/\(current)"
      }
    } catch {
      guard showingReviewMode, project?.path == root.path, reviewModeProject == root.path,
        workspace.reviewRepositoryEpoch == epoch else {
        return
      }
      reviewModeError = "无法加载分支：\(error.localizedDescription)"
    }
  }

  func startCodeReview(_ scope: ModelCodeReviewScope) async {
    guard showingReviewMode, let root = project, reviewModeProject == root.path,
      !reviewModeStarting
    else { return }
    reviewModeStarting = true
    reviewModeError = nil
    do {
      let snapshot = try await workspace.modelReviewSnapshot(scope: scope)
      guard showingReviewMode, project?.path == root.path, reviewModeProject == root.path else {
        return
      }
      let configuredDelivery = library.gitPreferences.reviewDelivery
      let inlineTask = selectedTask.flatMap { task in
        task.project == root.path && !task.archived && canStartChat(taskID: task.id) ? task : nil
      }
      let usesDetachedTask = configuredDelivery == .detached || inlineTask == nil
      let effectiveDelivery: ReviewDelivery = usesDetachedTask ? .detached : .inline
      let detachedTask = usesDetachedTask ? createPendingReviewTask(project: root.path) : nil
      let targetTaskID = usesDetachedTask ? detachedTask?.id : inlineTask?.id
      let runsBefore = Set(library.chatRuns.map(\.id))
      await startChat(
        snapshot.requestTitle, taskID: targetTaskID,
        review: ModelCodeReviewContext(snapshot: snapshot, delivery: effectiveDelivery))
      let createdRun = library.chatRuns.last { !runsBefore.contains($0.id) }
      if let detachedTask {
        if createdRun != nil,
          let task = library.tasks.first(where: { $0.id == detachedTask.id })
        {
          applyTaskSelection(task)
        } else {
          removePendingReviewTask(detachedTask.id)
        }
      }
      guard createdRun != nil else {
        reviewModeError = error ?? "无法启动代码审查。"
        reviewModeStarting = false
        return
      }
      dismissCodeReviewMode()
    } catch {
      reviewModeError = "无法启动代码审查：\(error.localizedDescription)"
      reviewModeStarting = false
    }
  }

  private func createPendingReviewTask(project: String) -> WorkspaceTask {
    let now = Date()
    let task = WorkspaceTask(
      id: UUID().uuidString, project: project, title: "代码审查", runIDs: [],
      popoutDraft: true, createdAt: now, updatedAt: now)
    library.tasks.insert(task, at: 0)
    saveLibrary()
    return task
  }

  private func removePendingReviewTask(_ id: String) {
    library.tasks.removeAll { $0.id == id && $0.isPopoutDraft && $0.runIDs.isEmpty }
    library.drafts[id] = nil
    library.draftImages[id] = nil
    library.draftFiles[id] = nil
    saveLibrary()
  }
}
