import AppKit
import Observation

@MainActor @Observable
final class DeveloperWorkspace {
  var root: URL?
  var files: [String] = []
  var fileQuery = ""
  var selectedFile: String?
  var openFiles: [String] = []
  var fileText = ""
  var fileLoading = false
  var fileError: String?
  var filesError: String?
  var fileFocusRequest = UUID()
  var showingFileLine = false
  var fileLineRange: NSRange?
  var fileLineRequest = UUID()
  @ObservationIgnored var filePreviewPositions: [String: FilePreviewPosition] = [:]
  @ObservationIgnored private let fileReader: @Sendable (String, URL) async throws -> String

  init(fileReader: @escaping @Sendable (String, URL) async throws -> String = { path, root in
    try await Task.detached { try LocalWorkspaceService.read(path, root: root) }.value
  }) {
    self.fileReader = fileReader
  }
  var gitFiles: [GitFile] = []
  var gitBranch = ""
  var gitAvailable = false
  var canCommit = false
  var reviewScope = GitReviewScope.unstaged
  var reviewCommits: [GitReviewChoice] = []
  var reviewBranches: [GitReviewChoice] = []
  var reviewCommit = ""
  var reviewBaseBranch = ""
  var historicalFiles: [GitFile] = []
  var reviewLoading = false
  var gitRefreshing = false
  var batchSnapshot: GitBatchSnapshot?
  var batchError: String?
  var discardPlan: GitDiscardPlan?
  var reviewSnapshot = UUID()
  var reviewArguments: [String] = []
  var collapsedReviewFiles: Set<String> = []
  var reviewPath: String?
  var diff = ""
  var error: String?
  var loading = false
  var gitBusy = false
  var commitMessage = ""
  var generatingCommitMessage = false
  var commitGenerationError: String?
  var gitActionStatus: String?
  var showingCommitPush = false
  var showingPullRequest = false
  var pullRequestDraft = GitHubPRDraft()
  var gitActionRunning = false
  var gitActionPhase = ""
  @ObservationIgnored var gitActionToken: UUID?
  @ObservationIgnored var pushOperation: UUID?
  @ObservationIgnored var commitGenerationTask: Task<Void, Never>?
  @ObservationIgnored var commitGenerationToken: UUID?
  var browser = BrowserSession()
  var terminals = TerminalSessions()
  private var generation = UUID()
  private var fileVersion = UUID()
  private var diffVersion = UUID()
  private var gitVersion = UUID()

  func setProject(_ root: URL?) {
    showingCommitPush = false
    showingPullRequest = false
    pullRequestDraft.cancelLoading()
    pullRequestDraft = GitHubPRDraft()
    gitActionRunning = false
    gitActionToken = nil
    gitActionStatus = nil
    pushOperation = nil
    cancelCommitMessageGeneration()
    commitMessage = ""
    commitGenerationError = nil
    generation = UUID()
    diffVersion = UUID()
    gitVersion = UUID()
    fileVersion = UUID()
    self.root = root
    loading = false
    gitBusy = false
    files = []
    openFiles = []
    selectedFile = nil
    fileText = ""
    fileLoading = false
    fileError = nil
    filesError = nil
    showingFileLine = false
    fileLineRange = nil
    filePreviewPositions.removeAll()
    gitFiles = []
    gitAvailable = false
    canCommit = false
    gitBranch = ""
    reviewScope = .unstaged
    reviewCommits = []
    reviewBranches = []
    reviewCommit = ""
    reviewBaseBranch = ""
    historicalFiles = []
    reviewLoading = false
    gitRefreshing = false
    batchSnapshot = nil
    batchError = nil
    discardPlan = nil
    reviewSnapshot = UUID()
    reviewArguments = []
    collapsedReviewFiles = []
    reviewPath = nil
    diff = ""
    error = nil
    guard root != nil else { return }
    Task {
      await refreshFiles()
      await refreshGit()
    }
  }
  func refreshFiles() async {
    guard let root else { return }
    let token = generation
    loading = true
    filesError = nil
    defer { if token == generation { loading = false } }
    do {
      let paths = try await LocalWorkspaceService.files(at: root)
      if token == generation { files = paths }
    } catch { if token == generation { filesError = error.localizedDescription } }
  }
  func openFile(_ path: String) async {
    await selectFile(path)?.value
  }

  /// Select synchronously: a delayed fallback must never reopen a closed tab.
  @discardableResult
  func selectFile(_ path: String) -> Task<Void, Never>? {
    guard let root else { return nil }
    let token = UUID()
    fileVersion = token
    selectedFile = path
    if !openFiles.contains(path) { openFiles.append(path) }
    fileText = ""
    fileError = nil
    fileLoading = true
    showingFileLine = false
    fileLineRange = nil
    fileFocusRequest = UUID()
    let reader = fileReader
    return Task { [weak self] in
      let result: Result<String, Error>
      do { result = .success(try await reader(path, root)) }
      catch { result = .failure(error) }
      guard let self, self.fileVersion == token, self.root == root,
        self.selectedFile == path, self.openFiles.contains(path) else { return }
      self.fileLoading = false
      switch result {
      case .success(let text): self.fileText = text
      case .failure(let error): self.fileError = error.localizedDescription
      }
    }
  }

  func closeFile(_ path: String) {
    guard let index = openFiles.firstIndex(of: path) else { return }
    openFiles.remove(at: index)
    filePreviewPositions[(root?.path ?? "") + "/" + path] = nil
    guard selectedFile == path else { return }
    fileVersion = UUID()
    selectedFile = nil
    fileText = ""
    fileError = nil
    fileLoading = false
    showingFileLine = false
    fileLineRange = nil
    if !openFiles.isEmpty { selectFile(openFiles[min(index, openFiles.count - 1)]) }
  }

  func moveFile(_ offset: Int) {
    guard let path = selectedFile, let index = openFiles.firstIndex(of: path), openFiles.count > 1 else { return }
    let next = ((index + offset) % openFiles.count + openFiles.count) % openFiles.count
    selectFile(openFiles[next])
  }

  func jumpToFileLine(_ value: String) -> Bool {
    guard !fileLoading, fileError == nil,
      let range = FileLineLocation.range(value, in: fileText) else { return false }
    fileLineRange = range
    fileLineRequest = UUID()
    showingFileLine = false
    fileFocusRequest = UUID()
    return true
  }

  func refreshGit() async {
    guard let root else { return }
    let token = UUID()
    gitVersion = token
    gitRefreshing = true
    defer { if token == gitVersion { gitRefreshing = false } }
    do {
      let status = try await LocalWorkspaceService.git(
        ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "."], at: root)
      let branch = try await LocalWorkspaceService.git(
        ["symbolic-ref", "--short", "HEAD"], at: root)
      let repository = try await LocalWorkspaceService.git(
        ["rev-parse", "--show-toplevel"], at: root)
      guard token == gitVersion else { return }
      canCommit =
        repository.status == 0
        && URL(fileURLWithPath: repository.text.trimmingCharacters(in: .whitespacesAndNewlines))
          .resolvingSymlinksInPath().standardizedFileURL.path
          == root.resolvingSymlinksInPath().standardizedFileURL.path
      gitAvailable = status.status == 0
      gitFiles = gitAvailable ? GitFile.parse(status.text) : []
      gitBranch =
        branch.status == 0
        ? branch.text.trimmingCharacters(in: .whitespacesAndNewlines) : "detached HEAD"
      guard gitAvailable else {
        reviewCommits = []
        reviewBranches = []
        historicalFiles = []
        diff = ""
        return
      }
      let commits = try await GitReviewService.commits(at: root)
      let branches = try await GitReviewService.branches(at: root)
      guard token == gitVersion else { return }
      reviewCommits = commits
      reviewBranches = branches
      if !commits.contains(where: { $0.id == reviewCommit }) {
        reviewCommit = commits.first?.id ?? ""
      }
      if !branches.contains(where: { $0.id == reviewBaseBranch }) { reviewBaseBranch = "" }
      await loadDiff()
    } catch { if token == gitVersion { self.error = error.localizedDescription } }
  }
  var visibleChanges: [GitFile] {
    reviewScope.isHistorical
      ? historicalFiles : gitFiles.filter { reviewScope == .staged ? $0.staged : $0.unstaged }
  }
  func loadDiff() async {
    guard let root else { return }
    let token = UUID()
    diffVersion = token
    let scope = reviewScope
    let selection = scope == .commit ? reviewCommit : reviewBaseBranch
    let path = reviewPath
    func isCurrent() -> Bool {
      token == diffVersion && self.root == root && scope == reviewScope && path == reviewPath
        && selection == (scope == .commit ? reviewCommit : reviewBaseBranch)
    }
    reviewLoading = true
    defer { if token == diffVersion { reviewLoading = false } }
    diff = ""
    historicalFiles = []
    reviewArguments = []
    error = nil
    batchSnapshot = nil
    batchError = nil
    if scope.isHistorical && selection.isEmpty { return }
    do {
      if let path,
        gitFiles.first(where: { $0.path == path })?.untracked == true && scope == .unstaged
      {
        let text = try await Task.detached { try LocalWorkspaceService.read(path, root: root) }
          .value
        if isCurrent() {
          diff =
            "+++ " + path + "\n"
            + text.components(separatedBy: "\n").map { "+" + $0 }.joined(separator: "\n")
        }
        return
      }
      let args = try await GitReviewService.arguments(scope: scope, selection: selection, at: root)
      let changes =
        scope.isHistorical ? try await GitReviewService.files(arguments: args, at: root) : []
      let result = try await GitReviewService.checked(args + ["--", path ?? "."], at: root)
      var batch: GitBatchSnapshot?
      var batchFailure: String?
      if !scope.isHistorical {
        do { batch = try await GitBatchService.capture(scope: scope, at: root) } catch {
          batchFailure = error.localizedDescription
        }
      }
      if isCurrent() {
        historicalFiles = changes
        diff = result
        reviewArguments = args
        reviewSnapshot = UUID()
        batchSnapshot = batch
        batchError = batchFailure
        if let batch { gitFiles = batch.files }
      }
    } catch { if isCurrent() { self.error = error.localizedDescription } }
  }
  func stage(_ path: String, undo: Bool) async {
    guard let root, !gitBusy, !reviewScope.isHistorical else { return }
    gitBusy = true
    error = nil
    defer { gitBusy = false }
    do {
      let status = try await GitReviewService.checked(
        ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "."], at: root)
      let file = GitFile.parse(status).first { $0.path == path }
      let paths = file?.comparisonPaths(scope: undo ? .staged : .unstaged) ?? [path]
      for path in paths { _ = try GitBatchService.gitPath(path, root: root) }
      let args: [String]
      if undo {
        let head = try await LocalWorkspaceService.git(["rev-parse", "--verify", "HEAD"], at: root)
        args =
          head.status == 0
          ? ["restore", "--staged", "--"] + paths : ["rm", "--cached", "--force", "--"] + paths
      } else {
        args = ["add", "--"] + paths
      }
      let result = try await LocalWorkspaceService.git(args, at: root)
      guard result.status == 0 else { throw AgentFailure(message: result.text) }
      await refreshGit()
    } catch { self.error = error.localizedDescription }
  }
  @discardableResult func commit() async -> Bool {
    guard let root, canCommit, !gitBusy, !reviewScope.isHistorical,
      !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return false }
    cancelCommitMessageGeneration()
    gitBusy = true
    error = nil
    let token = generation
    defer { if token == generation { gitBusy = false } }
    do {
      let output = try await LocalWorkspaceService.git(["commit", "-m", commitMessage], at: root)
      guard output.status == 0 else { throw AgentFailure(message: output.text) }
      guard token == generation else { return false }
      commitMessage = ""
      await refreshGit()
      return token == generation
    } catch {
      if token == generation { self.error = error.localizedDescription }
      return false
    }
  }
}
