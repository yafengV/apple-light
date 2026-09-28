import Foundation
import AppKit
import Observation

typealias GitHubPRGenerator = @Sendable (GitPullRequestContent, String, String) async throws -> GitPullRequestText

@MainActor @Observable final class GitHubPRDraft {
  var title = ""
  var body = ""
  var base = ""
  var includeLocalChanges = true
  private(set) var phase = ""
  private(set) var context: GitHubPRContext?
  private(set) var existing: GitHubPullRequest?
  private(set) var browserURL: URL?
  private(set) var error: String?
  private(set) var loading = false
  private(set) var creating = false
  private(set) var generating = false
  private(set) var needsRefresh = false
  private(set) var modalActionToken: UUID?
  var modalActionPending: Bool { modalActionToken != nil }
  @ObservationIgnored private var root: URL?
  @ObservationIgnored private var token = UUID()
  @ObservationIgnored private let service: GitHubPRService
  @ObservationIgnored private var generationTask: Task<GitPullRequestText, Error>?

  init(service: GitHubPRService = GitHubPRService()) { self.service = service }
  var canCreate: Bool {
    context != nil && context?.creationProblem == nil && existing == nil && !loading && !creating && !needsRefresh
      && !base.isEmpty
      && (context?.allowsLocalPreparation != true || includeLocalChanges || context?.publishedCommit != nil)
  }
  var needsGeneratedContent: Bool {
    title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func load(at root: URL, allowUnpublished: Bool = false) async {
    guard !creating else { return }
    if self.root != root { title = ""; body = ""; base = "" }
    self.root = root
    let operation = UUID(); token = operation
    context = nil; existing = nil; browserURL = nil; error = nil; loading = true
    defer { if token == operation { loading = false } }
    do {
      let value = try await service.inspect(at: root, allowUnpublished: allowUnpublished)
      guard token == operation, !Task.isCancelled else { return }
      context = value; existing = value.existing; needsRefresh = false
      if base.isEmpty { base = value.defaultBranch }
    } catch {
      if token == operation, !Task.isCancelled { self.error = error.localizedDescription }
    }
  }

  func cancelLoading() {
    cancelGeneration()
    guard !creating else { return }
    token = UUID(); loading = false
  }

  // Selecting a PR action closes the modal while its background workflow continues.
  func modalDidDisappear(handingOffAction: Bool = false) {
    guard !creating, !modalActionPending else { return }
    cancelLoading()
    if !handingOffAction { resetInputs() }
  }

  /// Mirrors the reference modal's reset; metadata and operation results belong to the workflow.
  private func resetInputs() { title = ""; body = ""; includeLocalChanges = true }

  func reserveModalAction() -> UUID? {
    guard !loading, !creating, !modalActionPending else { return nil }
    let reservation = UUID(); modalActionToken = reservation
    return reservation
  }
  func finishModalAction(_ reservation: UUID, reset: Bool) {
    guard modalActionToken == reservation else { return }
    modalActionToken = nil
    if reset { resetInputs() }
  }

  func cancelGeneration() { generationTask?.cancel() }
  func reportError(_ message: String) { error = message }
  func clearError() { error = nil }

  @discardableResult func create(draft: Bool, generate: GitHubPRGenerator? = nil,
    prepareLocalChanges: Bool? = nil, commitMessage: String = "", forceWithLease: Bool = false,
    onCommitMessage: @escaping @MainActor (String) -> Void = { _ in },
    onCommitted: @escaping @MainActor () -> Void = {},
    onPushed: @escaping @MainActor (String) -> Void = { _ in },
    browserOpener: (@MainActor (URL) -> Bool)? = nil,
    authorize: @escaping GitMutationAuthorization = {}) async -> GitHubPullRequest? {
    guard canCreate, let context else { return nil }
    creating = true; error = nil; browserURL = nil
    phase = "正在检查分支与变更…"
    defer { creating = false; generating = false; generationTask = nil; phase = "" }
    let originalTitle = title, originalBody = body, originalBase = base
    let originalInclude = includeLocalChanges
    do {
      guard title.count <= 256, !title.contains("\n"), !title.contains("\r"), body.utf8.count <= 65_536 else {
        throw AgentFailure(message: "请填写 256 字符以内的单行标题，描述不能超过 64 KiB。")
      }
      var workflow: GitPullRequestWorkflow?
      if let prepareLocalChanges {
        workflow = try await GitPullRequestWorkflow.prepare(context, base: base,
          includeLocalChanges: prepareLocalChanges, service: service)
      }
      guard title == originalTitle, body == originalBody, base == originalBase,
        includeLocalChanges == originalInclude else {
        throw AgentFailure(message: "PR 内容已手动修改，未继续操作，请重新创建。")
      }
      var resolvedCommitMessage = commitMessage
      let needsCommitMessage = workflow?.selection != nil
        && commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      if needsGeneratedContent || needsCommitMessage {
        guard let generate else {
          throw AgentFailure(message: "请配置模型与 API 以生成 PR 内容，或手动填写标题和描述。")
        }
        let service = service
        generating = true
        phase = needsCommitMessage ? "正在生成提交说明与 PR 内容…" : "正在生成 PR 内容…"
        let task = Task {
          let content: GitPullRequestContent
          if let workflow { content = try await workflow.content(needsCommitMessage: needsCommitMessage) }
          else { content = try await service.generationContent(context, base: originalBase) }
          try Task.checkCancellation()
          let result = try await generate(content, originalTitle, originalBody)
          try Task.checkCancellation()
          if let workflow { try await workflow.validate(service: service) }
          else {
            guard try await service.generationContent(context, base: originalBase) == content else {
              throw GitHubPRRefreshRequired(message: "目标分支或变更已改变，请重新检查后生成。")
            }
          }
          try Task.checkCancellation()
          return result
        }
        generationTask = task
        let generated = try await withTaskCancellationHandler {
          try await task.value
        } onCancel: { task.cancel() }
        generating = false; generationTask = nil
        try Task.checkCancellation()
        guard title == originalTitle, body == originalBody, base == originalBase,
          includeLocalChanges == originalInclude else {
          throw AgentFailure(message: "PR 内容已手动修改，未继续操作，请重新创建。")
        }
        if originalTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { title = generated.title }
        if originalBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body = generated.body }
        if needsCommitMessage {
          guard let message = generated.commitMessage,
            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            message.utf8.count <= 16_384 else {
            throw AgentFailure(message: "模型未返回有效的提交说明，请重试或先手动填写提交说明。")
          }
          resolvedCommitMessage = message
        }
      }
      try Task.checkCancellation()
      // Validate the generated URL before any staging, commit or push.
      if browserOpener != nil {
        _ = try GitHubPRService.compareURL(repository: context.repository, base: base, head: context.head,
          title: title, body: body)
      }
      let finalTitle = title, finalBody = body
      let authorizeInput: GitMutationAuthorization = {
        guard self.title == finalTitle, self.body == finalBody, self.base == originalBase,
          self.includeLocalChanges == originalInclude else {
          throw AgentFailure(message: "PR 内容已手动修改，未继续操作，请重新创建。")
        }
        try authorize()
      }
      let destination: GitPullRequestDestination
      if let workflow {
        if workflow.selection != nil { onCommitMessage(resolvedCommitMessage) }
        destination = try await workflow.execute(service: service, title: title, body: body, draft: draft,
          commitMessage: resolvedCommitMessage, forceWithLease: forceWithLease,
          openInBrowser: browserOpener != nil, authorize: authorizeInput,
          onPhase: { self.phase = $0 }, onCommitted: onCommitted, onPushed: onPushed)
      } else if browserOpener != nil {
        phase = "正在准备浏览器 PR 页面…"
        destination = try await service.browserDestination(context, base: base, title: title, body: body,
          publishedOnly: false, authorize: authorizeInput)
      } else {
        phase = "正在创建 PR…"
        destination = .pullRequest(try await service.create(context, base: base, title: title, body: body,
          draft: draft, authorize: authorizeInput))
      }
      switch destination {
      case .pullRequest(let result):
        if let browserOpener {
          guard let url = context.repository.pullRequestURL(result.url) else {
            throw AgentFailure(message: "PR 地址无效。")
          }
          try authorizeInput()
          try Task.checkCancellation()
          guard browserOpener(url) else { throw AgentFailure(message: "无法打开系统浏览器，请重试。") }
          browserURL = url
        }
        existing = result
        return result
      case .browser(let url, let refreshed):
        try authorizeInput()
        try Task.checkCancellation()
        guard let browserOpener, browserOpener(url) else {
          throw AgentFailure(message: "无法打开系统浏览器，标题和描述已保留，请重试。")
        }
        browserURL = url
        // The destination already checked this head; do not delay the browser handoff with another inspection.
        self.context = refreshed
        return nil
      }
    } catch {
      if error is CancellationError { return nil }
      needsRefresh = error is GitHubPRRefreshRequired
      // A successful commit stays in Git after a later push failure. Reload that
      // head so retry can continue with push instead of creating another commit.
      if prepareLocalChanges != nil && !needsRefresh, let root {
        if let refreshed = try? await service.inspect(at: root, allowUnpublished: true) {
          self.context = refreshed; existing = refreshed.existing
        } else { needsRefresh = true }
      }
      self.error = error.localizedDescription
        + (needsRefresh ? "\n请重新检查 PR 状态后再尝试。" : "")
      return nil
    }
  }
}

extension WorkspaceStore {
  @discardableResult func recordPullRequest(_ pullRequest: GitHubPullRequest,
    for taskID: String?, at root: URL, repository: GitHubRepository) -> Bool {
    guard let taskID, let task = library.tasks.first(where: { $0.id == taskID }),
      task.project == root.path, let url = pullRequest.validatedURL,
      repository.pullRequestURL(url.absoluteString) != nil else { return false }
    var candidate = library
    var requests = candidate.taskPullRequests[taskID] ?? []
    if let index = requests.firstIndex(where: { $0.url == pullRequest.url }) {
      requests[index] = pullRequest
    } else {
      requests.insert(pullRequest, at: 0)
    }
    candidate.taskPullRequests[taskID] = requests
    do {
      try commitLibrary(candidate)
      return true
    } catch {
      self.error = "无法保存任务 PR：\(error.localizedDescription)"
      return false
    }
  }

  @discardableResult func updateRecordedPullRequest(_ updated: GitHubPullRequest,
    for taskID: String) -> Bool {
    guard library.tasks.contains(where: { $0.id == taskID }),
      let url = updated.validatedURL,
      let requests = library.taskPullRequests[taskID],
      let index = requests.firstIndex(where: { $0.validatedURL == url }),
      updated.number == requests[index].number,
      updated.isCrossRepository == requests[index].isCrossRepository else { return false }
    var candidate = library
    var replacement = requests
    replacement[index] = updated
    candidate.taskPullRequests[taskID] = replacement
    do {
      try commitLibrary(candidate)
      return true
    } catch {
      self.error = "无法保存 PR 最新状态：\(error.localizedDescription)"
      return false
    }
  }

  func createPullRequest(in workspace: DeveloperWorkspace, draft: Bool, taskID: String? = nil,
    openInBrowser: Bool = false,
    openURL: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) async {
    guard !library.gitPreferences.readOnlyReview, !workspace.gitBusy, !workspace.gitActionRunning,
      workspace.isPrimaryReviewRepository,
      let root = workspace.gitRoot, workspace.pullRequestDraft.canCreate,
      let repository = workspace.pullRequestDraft.context?.repository else { return }
    let state = workspace.pullRequestDraft
    let generation = workspace.generationForGitMutation, epoch = workspace.reviewRepositoryEpoch
    let action = UUID(), originalCommitMessage = workspace.commitMessage
    var expectedCommitMessage = originalCommitMessage
    let prepare = state.context?.allowsLocalPreparation == true ? state.includeLocalChanges : nil
    let originalTitle = state.title, originalBody = state.body, originalBase = state.base
    let originalInclude = state.includeLocalChanges
    let authorizeContext = workspace.gitMutationAuthorization(at: root)
    let authorize: GitMutationAuthorization = {
      try authorizeContext()
      guard workspace.pullRequestDraft === state,
        workspace.isPrimaryReviewRepository, workspace.commitMessage == expectedCommitMessage,
        !self.library.gitPreferences.readOnlyReview else { throw CancellationError() }
    }
    workspace.gitBusy = true
    if prepare != nil { workspace.gitActionRunning = true; workspace.gitActionToken = action }
    defer {
      if workspace.generationForGitMutation == generation { workspace.gitBusy = false }
      if workspace.gitActionToken == action {
        workspace.gitActionRunning = false; workspace.gitActionToken = nil; workspace.gitActionPhase = ""
      }
    }
    let generator: GitHubPRGenerator?
    do {
      var needsCommitMessage = false
      if prepare == true && originalCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let changes = try await GitBatchService.capture(scope: .unstaged, at: root)
        needsCommitMessage = changes.files.contains { $0.staged || $0.unstaged }
      }
      try authorize()
      guard state.title == originalTitle, state.body == originalBody, state.base == originalBase,
        state.includeLocalChanges == originalInclude else { return }
      if state.needsGeneratedContent || needsCommitMessage {
        let configuration = modelConfiguration
        try configuration.validateEndpoint()
        let key = try ModelKeychain.read(account: configuration.credentialAccount)
        let instructions = library.gitPreferences.pullRequestInstructions
        let commitInstructions = library.gitPreferences.commitInstructions
        let generate = GitTextGenerator.make(config: configuration, key: key, repository: root,
          dataRoot: dataRoot, executable: executable)
        generator = { content, title, body in
          let text = try await generate(content.messages(instructions: instructions, title: title,
            body: body, commitInstructions: commitInstructions))
          return try GitPullRequestText.parse(text)
        }
      } else { generator = nil }
    } catch {
      if !(error is CancellationError), workspace.reviewRepositoryEpoch == epoch {
        state.reportError(error.localizedDescription)
      }
      return
    }
    let result = await state.create(draft: draft, generate: generator,
      prepareLocalChanges: prepare, commitMessage: originalCommitMessage,
      forceWithLease: library.gitPreferences.alwaysForcePush,
      onCommitMessage: { message in
        guard (try? authorize()) != nil else { return }
        workspace.commitMessage = message; expectedCommitMessage = message
      }, onCommitted: {
        guard workspace.generationForGitMutation == generation, workspace.reviewRepositoryEpoch == epoch else { return }
        workspace.commitMessage = ""; expectedCommitMessage = ""
        workspace.gitActionStatus = openInBrowser ? "本地变更已提交，继续推送并打开 PR 页面" : "本地变更已提交，继续推送并创建 PR"
      }, onPushed: { status in
        guard workspace.generationForGitMutation == generation, workspace.reviewRepositoryEpoch == epoch else { return }
        workspace.gitActionStatus = status
      }, browserOpener: openInBrowser ? openURL : nil, authorize: authorize)
    if let result, workspace.gitRoot == root, workspace.pullRequestDraft === state,
      workspace.reviewRepositoryEpoch == epoch, workspace.generationForGitMutation == generation {
      workspace.gitActionStatus = "已创建或找到 PR #\(result.number)"
      if let project = workspace.root {
        _ = recordPullRequest(result, for: taskID, at: project, repository: repository)
      }
    }
    if state.browserURL != nil, workspace.pullRequestDraft === state,
      workspace.reviewRepositoryEpoch == epoch, workspace.generationForGitMutation == generation {
      workspace.gitActionStatus = "已在浏览器中打开 PR 页面"
    }
    if prepare != nil, workspace.generationForGitMutation == generation,
      workspace.reviewRepositoryEpoch == epoch { await workspace.refreshGit() }
  }
}
