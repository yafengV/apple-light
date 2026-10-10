import AppKit
import Observation

@MainActor @Observable
final class DeveloperWorkspace {
  var root: URL?
  private(set) var additionalFileRoots: [URL] = []
  var fileRoots: [URL] { WorkspaceFileScope.roots(primary: root, additional: additionalFileRoots) }
  var files: [String] = []
  var fileQuery = ""
  var fileTreeVisible = true
  var selectedFile: String?
  var openFiles: [String] = []
  var fileText = "" {
    didSet {
      if !oldValue.utf8.elementsEqual(fileText.utf8) {
        fileContentVersion = UUID()
        fileFind.refresh(in: fileText)
      }
    }
  }
  private(set) var fileContentVersion = UUID()
  let fileFind = FileFindSession()
  let selectionEdit = FileSelectionEditSession()
  var fileLoading = false
  var fileIsReadOnly = false
  var fileError: String?
  var fileOpenError: String?
  var fileOpenRequest = UUID()
  var fileEditorSessions: [String: FileEditorSession] = [:]
  var recoveredFileDrafts: [String: FileEditorRecoveryDraft] = [:]
  @ObservationIgnored var fileEditorRecoveryContext: FileEditorRecoveryContext?
  @ObservationIgnored var previousFileEditorRecoveryContexts: Set<FileEditorRecoveryContext> = []
  @ObservationIgnored var fileEditorRecoverySelections: [String: FileEditorRecoveryVersion] = [:]
  @ObservationIgnored var pendingFileEditorRecoveryResolutions: Set<String> = []
  @ObservationIgnored var fileEditingAllowed: () -> Bool = { true }
  @ObservationIgnored var onFileEditResolved: ((String) -> Void)?
  var fileCloseRequest: String?
  @ObservationIgnored var fileAutosaveTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored var fileMonitorTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored var fileMonitorTokens: [String: UUID] = [:]
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
  var gitReadError: String?
  var gitRepositoryRoot: URL?
  var reviewRepositories: [GitReviewRepository] = []
  var reviewRepositoryErrors: [String: String] = [:]
  var selectedReviewRepository: String?
  @ObservationIgnored var reviewRepositoryEpoch = UUID()
  @ObservationIgnored var reviewRepositoryDrafts: [String: GitReviewRepositoryDraft] = [:]
  var gitRoot: URL? {
    guard let repository = gitRepositoryRoot, let root else { return root }
    return GitBranchService.canonicalRoot(root).path == repository.path ? root : repository
  }
  var canCommit = false
  var selectedReviewScope = GitReviewScope.unstaged
  var gitReviewLastTurnOnly = false
  var reviewScopeOptions: [GitReviewScope] {
    gitReviewLastTurnOnly ? [.lastTurn] : GitReviewScope.allCases
  }
  var reviewScope: GitReviewScope {
    get { gitReviewLastTurnOnly ? .lastTurn : selectedReviewScope }
    set { selectedReviewScope = newValue }
  }
  var lastTurnReview: LastTurnReviewSnapshot?
  @ObservationIgnored var lastTurnDataRoot: URL?
  @ObservationIgnored var lastTurnReviewSource: () -> LastTurnReviewSource? = { nil }
  @ObservationIgnored var lastTurnRequest = UUID()
  @ObservationIgnored var readLastTurnSnapshot: @Sendable (LastTurnReviewSource, URL) async throws -> LastTurnReviewSnapshot = {
    source, root in try await Task.detached { try LastTurnReviewSnapshot.load(source, dataRoot: root) }.value
  }
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
  var managedBranchSetup = GitManagedBranchSetup()
  var managedBranchRequest: GitManagedBranchRequest?
  var showingManagedBranchSetup = false
  var gitCommands = GitWorkflowCommandState()
  var pullRequestLinkOpening = GitPullRequestLinkOpening()
  let pullRequestMergeCommand = GitPullRequestMergeCommandState()
  var gitPresentationTaskID: String?
  var gitPresentationForceDraft = false
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
  @ObservationIgnored var isGitReviewReadOnly: () -> Bool = { false }
  var generationForGitMutation: UUID { generation }
  private var generation = UUID()
  private var fileVersion = UUID()
  private var filesVersion = UUID()
  private var diffVersion = UUID()
  private var gitVersion = UUID()

  func setProject(_ root: URL?, additionalFolders: [URL] = []) {
    showingCommitPush = false
    showingPullRequest = false
    clearGitPresentation()
    gitCommands.cancel()
    pullRequestLinkOpening.cancel()
    pullRequestMergeCommand.cancel()
    showingManagedBranchSetup = false
    managedBranchRequest = nil
    managedBranchSetup.cancel()
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
    filesVersion = UUID()
    for task in fileAutosaveTasks.values { task.cancel() }
    fileAutosaveTasks.removeAll()
    stopFileMonitoring()
    fileFind.close()
    selectionEdit.reset()
    self.root = root
    additionalFileRoots = Array(WorkspaceFileScope.roots(primary: root, additional: additionalFolders).dropFirst())
    loading = false
    gitBusy = false
    files = []
    openFiles = []
    selectedFile = nil
    fileText = ""
    fileLoading = false
    fileIsReadOnly = false
    fileError = nil
    fileOpenError = nil
    fileOpenRequest = UUID()
    fileCloseRequest = nil
    filesError = nil
    showingFileLine = false
    fileLineRange = nil
    filePreviewPositions.removeAll()
    gitFiles = []
    gitAvailable = false
    gitReadError = nil
    gitRepositoryRoot = nil
    reviewRepositories = []
    reviewRepositoryErrors = [:]
    selectedReviewRepository = nil
    reviewRepositoryEpoch = UUID()
    reviewRepositoryDrafts = [:]
    canCommit = false
    gitBranch = ""
    reviewScope = .unstaged
    lastTurnReview = nil
    lastTurnRequest = UUID()
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
    let token = generation, filesToken = filesVersion, gitToken = gitVersion
    Task {
      guard generation == token else { return }
      if filesVersion == filesToken { await refreshFiles() }
      if generation == token && gitVersion == gitToken { await refreshGit() }
    }
  }
  func refreshFiles() async {
    guard let primary = fileRoots.first else { return }
    let roots = fileRoots, token = UUID()
    filesVersion = token
    loading = true
    filesError = nil
    defer { if token == filesVersion { loading = false } }
    var paths: [String] = [], failures: [String] = [], seen = Set<String>()
    for root in roots {
      do {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
          isDirectory.boolValue, FileManager.default.isReadableFile(atPath: root.path) else {
          throw AgentFailure(message: "文件夹不可用：\(root.path)")
        }
        for path in try await LocalWorkspaceService.files(at: root) {
          guard let location = try? WorkspaceFileScope.location(root.appendingPathComponent(path).path, roots: roots),
            seen.insert(location.url.path).inserted else { continue }
          paths.append(WorkspaceFileScope.key(location, primary: primary))
        }
      } catch { failures.append(error.localizedDescription) }
      guard token == filesVersion, !Task.isCancelled else { return }
    }
    files = paths
    filesError = failures.isEmpty ? nil : failures.joined(separator: "\n")
  }

  func fileLocation(_ path: String) throws -> WorkspaceFileLocation {
    try WorkspaceFileScope.location(path, roots: fileRoots)
  }

  var fileGroups: [WorkspaceFileGroup] {
    let roots = fileRoots
    guard let primary = roots.first else { return [] }
    var grouped: [String: [String]] = [:]
    // Listing already canonicalizes entries. Rendering must not resolve every
    // file on disk again; selection/opening revalidates the actual destination.
    for path in files {
      if path.hasPrefix("/") {
        guard let folder = roots.first(where: { path.hasPrefix($0.path + "/") }) else { continue }
        grouped[folder.path, default: []].append(String(path.dropFirst(folder.path.count + 1)))
      } else {
        grouped[primary.path, default: []].append(path)
      }
    }
    return roots.map { .init(root: $0, paths: grouped[$0.path] ?? []) }
  }

  func setAdditionalFileRoots(_ additional: [URL]) {
    let updated = Array(WorkspaceFileScope.roots(primary: root, additional: additional).dropFirst())
    guard updated != additionalFileRoots else { return }
    additionalFileRoots = updated
    rememberReviewRepositoryDraft()
    invalidateGitReviewContext()
    filesVersion = UUID()
    fileVersion = UUID()
    fileOpenRequest = UUID()
    fileOpenError = nil
    let retained = openFiles.filter { (try? fileLocation($0)) != nil }
    for path in openFiles where !retained.contains(path) { closeFile(path, preservingDraft: true) }
    if let selectedFile { selectFile(selectedFile) }
    let token = filesVersion
    let epoch = reviewRepositoryEpoch, gitToken = gitVersion
    Task {
      if filesVersion == token { await refreshFiles() }
      if reviewRepositoryEpoch == epoch && gitVersion == gitToken { await refreshGit() }
    }
  }
  func openFile(_ path: String) async {
    await selectFile(path)?.value
  }

  /// Select synchronously: a delayed fallback must never reopen a closed tab.
  @discardableResult
  func selectFile(_ requestedPath: String) -> Task<Void, Never>? {
    guard let root else { return nil }
    let path = (try? fileLocation(requestedPath)).map {
      WorkspaceFileScope.key($0, primary: fileRoots.first ?? root)
    } ?? requestedPath
    let token = UUID()
    fileVersion = token
    stopFileMonitoring(path)
    selectionEdit.reset()
    if selectedFile != path { fileFind.close() }
    selectedFile = path
    if !openFiles.contains(path) { openFiles.append(path) }
    fileText = ""
    fileError = nil
    fileOpenError = nil
    fileOpenRequest = UUID()
    fileLoading = true
    fileIsReadOnly = false
    showingFileLine = false
    fileLineRange = nil
    fileFocusRequest = UUID()
    if let session = fileEditorSessions[editorKey(for: path)],
      session.hasUnsavedChanges || session.saving {
      fileText = session.text
      fileLoading = false
      startFileMonitoring(path)
      return nil
    }
    if fileEditorSessions[editorKey(for: path)] == nil,
      let recovered = recoveredFileDrafts[editorKey(for: path)] {
      fileEditorRecoverySelections[editorKey(for: path)] = recovered.version
      fileEditorSessions[editorKey(for: path)] = FileEditorSession(
        baseText: recovered.baseText, text: recovered.text)
      fileText = recovered.text
      fileLoading = false
      startFileMonitoring(path)
      return nil
    }
    let reader = fileReader
    let roots = fileRoots
    return Task { [weak self] in
      let result: Result<(String, Bool), Error>
      do {
        let location = try WorkspaceFileScope.location(path, roots: roots)
        let text = try await reader(location.path, location.root)
        let large = (try? LocalWorkspaceService.isLargeTextFile(location.path, root: location.root)) ?? false
        result = .success((text, large))
      }
      catch { result = .failure(error) }
      guard let self, self.fileVersion == token, self.root == root,
        self.selectedFile == path, self.openFiles.contains(path) else { return }
      self.fileLoading = false
      switch result {
      case .success(let (text, large)):
        self.fileText = text
        self.fileIsReadOnly = large
        self.fileEditorSessions[self.editorKey(for: path)] = large ? nil : FileEditorSession(baseText: text, text: text)
        self.startFileMonitoring(path)
      case .failure(let error): self.fileError = error.localizedDescription
      }
    }
  }

  func closeFile(_ path: String, preservingDraft: Bool = false) {
    guard let index = openFiles.firstIndex(of: path) else { return }
    let key = editorKey(for: path)
    if !preservingDraft, let session = fileEditorSessions[key], session.hasUnsavedChanges || session.saving {
      if fileCloseRequest != path { cancelFileClose() }
      fileAutosaveTasks.removeValue(forKey: key)?.cancel()
      fileCloseRequest = path
      return
    }
    if !preservingDraft {
      fileEditorSessions[key] = nil
      recoveredFileDrafts[key] = nil
      onFileEditResolved?(key)
    }
    fileAutosaveTasks.removeValue(forKey: key)?.cancel()
    stopFileMonitoring(path)
    openFiles.remove(at: index)
    filePreviewPositions[(root?.path ?? "") + "/" + path] = nil
    guard selectedFile == path else { return }
    fileVersion = UUID()
    fileFind.close()
    selectionEdit.reset()
    selectedFile = nil
    fileText = ""
    fileError = nil
    fileOpenError = nil
    fileOpenRequest = UUID()
    fileLoading = false
    fileIsReadOnly = false
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
    guard let project = root else { return }
    let folders = fileRoots
    let token = UUID()
    gitVersion = token
    // A status refresh supersedes older diff requests and their write snapshots.
    diffVersion = UUID()
    lastTurnRequest = UUID()
    lastTurnReview = nil
    reviewLoading = false
    reviewArguments = []
    batchSnapshot = nil
    discardPlan = nil
    gitRefreshing = true
    defer { if token == gitVersion { gitRefreshing = false } }
    var repository: URL?
    do {
      let discovery = await GitReviewRepositories.discover(folders)
      guard token == gitVersion else { return }
      reviewRepositories = discovery.repositories
      reviewRepositoryErrors = discovery.folderErrors
      let selected = discovery.repositories.first { $0.id == selectedReviewRepository }
        ?? discovery.repositories.first { $0.isPrimary }
        ?? discovery.repositories.first
      if let selected {
        if gitRepositoryRoot?.path != selected.id {
          // Explicit selections apply their own draft before refresh; a removed
          // repository or automatic fallback must also restore the target draft.
          if let previous = selectedReviewRepository, previous != selected.id { applyReviewRepositoryDraft(selected.id) }
        }
        selectedReviewRepository = selected.isPrimary && selectedReviewRepository == nil ? nil : selected.id
        if let failure = selected.readError { throw AgentFailure(message: failure) }
        repository = selected.root
      } else {
        selectedReviewRepository = nil
        if let failure = discovery.folderErrors[GitBranchService.canonicalRoot(project).path] {
          throw AgentFailure(message: failure)
        }
      }
      guard token == gitVersion else { return }
      if gitRepositoryRoot?.path != repository?.path {
        gitAvailable = false
        canCommit = false
      }
      gitRepositoryRoot = repository
      guard repository != nil, let root = gitRoot else {
        clearUnavailableGitReview()
        gitReadError = nil
        error = nil
        return
      }
      let status = try await GitReviewService.checked(
        ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "."], at: root)
      let branch = try await LocalWorkspaceService.git(
        ["symbolic-ref", "--short", "HEAD"], at: root)
      guard token == gitVersion else { return }
      let commits = try await GitReviewService.commits(at: root)
      let branches = try await GitReviewService.branches(at: root)
      guard token == gitVersion else { return }
      gitAvailable = true
      canCommit = true
      gitFiles = GitFile.parse(status)
      gitBranch =
        branch.status == 0
        ? branch.text.trimmingCharacters(in: .whitespacesAndNewlines) : "detached HEAD"
      reviewCommits = commits
      reviewBranches = branches
      if !commits.contains(where: { $0.id == reviewCommit }) {
        reviewCommit = commits.first?.id ?? ""
      }
      if !branches.contains(where: { $0.id == reviewBaseBranch }) { reviewBaseBranch = "" }
      gitReadError = nil
      await loadDiff()
    } catch {
      if token == gitVersion {
        clearUnavailableGitReview()
        // Preserve a root confirmed by Git, but never treat a failed discovery
        // as a resolved repository or as permission to initialize one.
        gitRepositoryRoot = repository
        gitReadError = error.localizedDescription
        self.error = error.localizedDescription
      }
    }
  }
  func scheduleGitRefresh() {
    let epoch = reviewRepositoryEpoch, token = gitVersion
    Task {
      if reviewRepositoryEpoch == epoch && gitVersion == token { await refreshGit() }
    }
  }
  func invalidateGitReviewContext() {
    reviewRepositoryEpoch = UUID()
    gitVersion = UUID()
    gitRefreshing = false
    clearUnavailableGitReview()
    gitRepositoryRoot = nil
    gitReadError = nil
    reviewPath = nil
    fileOpenRequest = UUID()
    fileOpenError = nil
    error = nil
    gitActionStatus = nil
    pullRequestDraft.cancelLoading()
    if !pullRequestDraft.creating { pullRequestDraft = GitHubPRDraft() }
  }
  private func clearUnavailableGitReview() {
    diffVersion = UUID()
    lastTurnRequest = UUID()
    lastTurnReview = nil
    gitAvailable = false
    canCommit = false
    gitFiles = []
    gitBranch = ""
    reviewCommits = []
    reviewBranches = []
    historicalFiles = []
    reviewLoading = false
    reviewArguments = []
    reviewSnapshot = UUID()
    batchSnapshot = nil
    batchError = nil
    discardPlan = nil
    diff = ""
    showingCommitPush = false
    showingPullRequest = false
    clearGitPresentation()
    gitCommands.cancel()
    pullRequestLinkOpening.cancel()
    pullRequestMergeCommand.cancel()
    showingManagedBranchSetup = false
    managedBranchRequest = nil
    managedBranchSetup.cancel()
    cancelCommitMessageGeneration()
  }
  var visibleChanges: [GitFile] {
    reviewScope.isHistorical
      ? historicalFiles : gitFiles.filter { reviewScope == .staged ? $0.staged : $0.unstaged }
  }
  func loadDiff() async {
    lastTurnRequest = UUID()
    if reviewScope == .lastTurn {
      diffVersion = UUID()
      await loadLastTurnReview()
      return
    }
    lastTurnReview = nil
    guard gitReadError == nil, let root = gitRoot else { return }
    let token = UUID()
    diffVersion = token
    let scope = reviewScope
    let selection = scope == .commit ? reviewCommit : reviewBaseBranch
    let path = reviewPath
    func isCurrent() -> Bool {
      token == diffVersion && gitRoot == root && scope == reviewScope && path == reviewPath
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
    guard let root = gitRoot, !gitBusy, canModifyReview else { return }
    let authorize = gitMutationAuthorization(at: root), token = generation, epoch = reviewRepositoryEpoch
    gitBusy = true
    error = nil
    defer { if generation == token { gitBusy = false } }
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
      try authorize()
      let result = try await LocalWorkspaceService.git(args, at: root)
      guard result.status == 0 else { throw AgentFailure(message: result.text) }
      if gitRoot == root, generation == token, reviewRepositoryEpoch == epoch { await refreshGit() }
    } catch {
      if gitRoot == root, generation == token, reviewRepositoryEpoch == epoch,
        !(error is CancellationError) { self.error = error.localizedDescription }
    }
  }
  @discardableResult func commit() async -> Bool {
    guard let root = gitRoot, canCommit, !gitBusy, canModifyReview,
      !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return false }
    cancelCommitMessageGeneration()
    gitBusy = true
    error = nil
    let token = generation, epoch = reviewRepositoryEpoch
    defer { if token == generation { gitBusy = false } }
    do {
      try gitMutationAuthorization(at: root)()
      let output = try await LocalWorkspaceService.git(["commit", "-m", commitMessage], at: root)
      guard output.status == 0 else { throw AgentFailure(message: output.text) }
      guard token == generation, reviewRepositoryEpoch == epoch else { return false }
      commitMessage = ""
      await refreshGit()
      return token == generation && reviewRepositoryEpoch == epoch
    } catch {
      if token == generation, reviewRepositoryEpoch == epoch { self.error = error.localizedDescription }
      return false
    }
  }
}
