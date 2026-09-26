import Foundation
import Observation

typealias GitHubPRGenerator = @Sendable (GitPullRequestContent, String, String) async throws -> GitPullRequestText

@MainActor @Observable final class GitHubPRDraft {
  var title = ""
  var body = ""
  var base = ""
  private(set) var context: GitHubPRContext?
  private(set) var existing: GitHubPullRequest?
  private(set) var error: String?
  private(set) var loading = false
  private(set) var creating = false
  private(set) var generating = false
  private(set) var needsRefresh = false
  @ObservationIgnored private var root: URL?
  @ObservationIgnored private var token = UUID()
  @ObservationIgnored private let service: GitHubPRService
  @ObservationIgnored private var generationTask: Task<GitPullRequestText, Error>?

  init(service: GitHubPRService = GitHubPRService()) { self.service = service }
  var canCreate: Bool {
    context != nil && context?.creationProblem == nil && existing == nil && !loading && !creating && !needsRefresh
      && !base.isEmpty
  }
  var needsGeneratedContent: Bool {
    title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func load(at root: URL) async {
    guard !creating else { return }
    if self.root != root { title = ""; body = ""; base = "" }
    self.root = root
    let operation = UUID(); token = operation
    context = nil; existing = nil; error = nil; loading = true
    defer { if token == operation { loading = false } }
    do {
      let value = try await service.inspect(at: root)
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

  func cancelGeneration() { generationTask?.cancel() }
  func reportError(_ message: String) { error = message }

  @discardableResult func create(draft: Bool, generate: GitHubPRGenerator? = nil) async -> GitHubPullRequest? {
    guard canCreate, let context else { return nil }
    creating = true; error = nil
    defer { creating = false; generating = false; generationTask = nil }
    do {
      guard title.count <= 256, !title.contains("\n"), !title.contains("\r"), body.utf8.count <= 65_536 else {
        throw AgentFailure(message: "请填写 256 字符以内的单行标题，描述不能超过 64 KiB。")
      }
      if needsGeneratedContent {
        guard let generate else {
          throw AgentFailure(message: "请配置模型与 API 以生成 PR 内容，或手动填写标题和描述。")
        }
        let originalTitle = title, originalBody = body, originalBase = base, service = service
        generating = true
        let task = Task {
          let content = try await service.generationContent(context, base: originalBase)
          try Task.checkCancellation()
          let result = try await generate(content, originalTitle, originalBody)
          try Task.checkCancellation()
          guard try await service.generationContent(context, base: originalBase) == content else {
            throw GitHubPRRefreshRequired(message: "目标分支或变更已改变，请重新检查后生成。")
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
        guard title == originalTitle, body == originalBody, base == originalBase else {
          throw AgentFailure(message: "PR 内容已手动修改，已保留输入，请重新创建。")
        }
        if originalTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { title = generated.title }
        if originalBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body = generated.body }
      }
      try Task.checkCancellation()
      let result = try await service.create(context, base: base, title: title, body: body, draft: draft)
      existing = result
      return result
    } catch {
      if error is CancellationError { return nil }
      needsRefresh = error is GitHubPRRefreshRequired
      self.error = error.localizedDescription
        + (needsRefresh ? "\n请重新检查 PR 状态后再尝试；标题和描述已保留。" : "")
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

  func createPullRequest(in workspace: DeveloperWorkspace, draft: Bool, taskID: String? = nil) async {
    guard !library.gitPreferences.readOnlyReview, !workspace.gitBusy, !workspace.gitActionRunning,
      let root = workspace.root, workspace.pullRequestDraft.canCreate,
      let repository = workspace.pullRequestDraft.context?.repository else { return }
    let state = workspace.pullRequestDraft
    let generator: GitHubPRGenerator?
    do {
      if state.needsGeneratedContent {
        let configuration = modelConfiguration
        _ = try configuration.endpoint("chat/completions")
        let key = try ModelKeychain.read(account: configuration.credentialAccount)
        let instructions = library.gitPreferences.pullRequestInstructions
        generator = { content, title, body in
          let result = try await ModelAPIClient().streamTurn(config: configuration, key: key,
            messages: content.messages(instructions: instructions, title: title, body: body), onDelta: { _ in })
          guard result.calls.isEmpty else { throw AgentFailure(message: "PR 生成返回了意外的工具请求。") }
          return try GitPullRequestText.parse(result.text)
        }
      } else { generator = nil }
    } catch {
      state.reportError(error.localizedDescription)
      return
    }
    workspace.gitBusy = true
    defer { if workspace.root == root, workspace.pullRequestDraft === state { workspace.gitBusy = false } }
    let result = await state.create(draft: draft, generate: generator)
    if let result, workspace.root == root, workspace.pullRequestDraft === state {
      workspace.gitActionStatus = "已创建或找到 PR #\(result.number)"
      _ = recordPullRequest(result, for: taskID, at: root, repository: repository)
    }
  }
}
