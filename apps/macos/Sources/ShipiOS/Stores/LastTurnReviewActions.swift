import Foundation

extension WorkspaceStore {
  func lastTurnReviewSource(taskID: String? = nil) -> LastTurnReviewSource? {
    guard let owner = taskID ?? selectedTask?.id,
      let run = taskWindowRuns(owner).last(where: {
        $0.kind == "chat" && $0.request["conversation_kind"].text != "compact"
      }) else { return nil }
    return lastTurnReviewSource(for: run)
  }

  func lastTurnReviewSource(for run: AgentRun) -> LastTurnReviewSource {
    let root: URL?
    if let path = run.codexTurnDiff?.pathBase, path.hasPrefix("/") {
      root = URL(fileURLWithPath: path, isDirectory: true)
    } else {
      // A new Git boundary, removed checkout, or handoff cannot establish the
      // original path base of a legacy snapshot. Display it without guessing.
      root = nil
    }
    return .init(runID: run.id, root: root, diff: run.codexTurnDiff)
  }

  func validateLastTurnAnchor(_ anchor: ReviewAnchor, taskID: String?) -> Bool {
    guard let id = anchor.turnRunID, let owner = taskID ?? selectedTask?.id,
      anchor.scope == GitReviewScope.lastTurn.title, anchor.revision == id,
      let run = taskWindowRuns(owner).first(where: { $0.id == id }),
      let root = lastTurnReviewSource(for: run).root,
      root.path == anchor.originRoot,
      let diff = run.codexTurnDiff,
      let text = try? CodexTurnDiffStorage.load(diff, root: dataRoot) else { return false }
    return CodexTurnDiffFiles.parse(text).contains {
      let patch = ReviewDiff($0.patch)
      return $0.path == anchor.path && patch.fingerprint == anchor.fingerprint
        && patch.lines.contains { line in
          line.canComment && line.oldLine == anchor.oldLine && line.newLine == anchor.newLine
            && String(line.text.dropFirst()) == anchor.code
        }
    }
  }

  func openLastTurnFile(_ file: CodexTurnDiffFile, snapshot: LastTurnReviewSnapshot,
    in workspace: DeveloperWorkspace, line: Int? = nil) async {
    guard workspace.lastTurnReview?.source == snapshot.source,
      workspace.lastTurnReviewSource() == snapshot.source,
      workspace.reviewScope == .lastTurn, let root = snapshot.source.root,
      snapshot.files.contains(file) else { return }
    let request = UUID(), generation = workspace.generationForGitMutation
    workspace.fileOpenRequest = request
    workspace.fileOpenError = nil
    do {
      let candidate = file.path.hasPrefix("/") ? URL(fileURLWithPath: file.path)
        : root.appendingPathComponent(file.path)
      let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
      let base = GitBranchService.canonicalRoot(root)
      guard resolved.path.hasPrefix(base.path + "/") else {
        throw AgentFailure(message: "回合文件不在已记录的目录内。")
      }
      let path = String(resolved.path.dropFirst(base.path.count + 1))
      try await ExternalEditorService.open(path, root: root, line: line, editor: preferredEditor)
    } catch {
      if workspace.generationForGitMutation == generation,
        workspace.lastTurnReview?.source == snapshot.source,
        workspace.lastTurnReviewSource() == snapshot.source,
        workspace.fileOpenRequest == request { workspace.fileOpenError = error.localizedDescription }
    }
  }
}

extension DeveloperWorkspace {
  func loadLastTurnReview() async {
    let request = UUID(), generation = generationForGitMutation
    lastTurnRequest = request
    let source = lastTurnReviewSource()
    reviewLoading = true
    error = nil
    lastTurnReview = nil
    fileOpenRequest = UUID()
    fileOpenError = nil
    diff = ""
    batchSnapshot = nil
    batchError = nil
    discardPlan = nil
    reviewArguments = []
    historicalFiles = []
    defer { if lastTurnRequest == request { reviewLoading = false } }
    guard let source else { return }
    let data = lastTurnDataRoot
    do {
      guard let data else { return }
      let snapshot = try await readLastTurnSnapshot(source, data)
      guard lastTurnRequest == request, generationForGitMutation == generation,
        reviewScope == .lastTurn, lastTurnReviewSource() == source else { return }
      lastTurnReview = snapshot
      diff = snapshot.unifiedDiff
      reviewSnapshot = UUID()
    } catch {
      if lastTurnRequest == request, generationForGitMutation == generation,
        reviewScope == .lastTurn, lastTurnReviewSource() == source { self.error = error.localizedDescription }
    }
  }
}
