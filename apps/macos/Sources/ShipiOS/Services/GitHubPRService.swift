import Foundation

struct GitHubPRService: Sendable {
  var executable: URL?
  init(executable: URL? = nil) { self.executable = executable }

  static func installedExecutable() -> URL? {
    ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh",
     NSHomeDirectory() + "/.local/bin/gh"].first(where: FileManager.default.isExecutableFile(atPath:))
      .map { URL(fileURLWithPath: $0) }
  }

  func run(_ args: [String], at root: URL, maxOutputBytes: Int = 1_048_576) async throws -> String {
    guard let executable = executable ?? Self.installedExecutable(),
      FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw AgentFailure(message: "尚未安装 GitHub CLI（gh）。安装后运行 gh auth login，再重新检查。")
    }
    try Task.checkCancellation()
    let result = try await LocalWorkspaceService.command(executable.path, args, at: root,
      maxOutputBytes: maxOutputBytes)
    guard result.status == 0 else { throw AgentFailure(message: result.text.isEmpty ? "GitHub CLI 操作失败。" : result.text) }
    return result.text
  }

  func inspect(at root: URL, remote selectedRemote: String? = nil,
    allowUnpublished: Bool = false) async throws -> GitHubPRContext {
    let choices = try await GitPushService.choices(at: root, allowDetached: allowUnpublished)
    let remote = selectedRemote ?? choices.preferredRemote
    guard choices.remotes.contains(remote), !remote.hasPrefix("-") else {
      throw AgentFailure(message: "所选远端已移除，请刷新后重试。")
    }
    let destination = remote == choices.preferredRemote ? choices.preferredDestination : choices.branch
    let repository = try GitHubRepository.parse(await GitPushService.remoteURL(remote, at: root))
    _ = try await run(["auth", "status", "--active", "--hostname", "github.com"], at: root)
    struct Metadata: Decodable {
      struct Branch: Decodable { let name: String }
      let nameWithOwner: String
      let defaultBranchRef: Branch?
    }
    let metadataText = try await run(["repo", "view", repository.fullName, "--json", "nameWithOwner,defaultBranchRef"], at: root)
    let metadata = try JSONDecoder().decode(Metadata.self, from: Data(metadataText.utf8))
    guard metadata.nameWithOwner.lowercased() == repository.fullName.lowercased(),
      let base = metadata.defaultBranchRef?.name, !base.isEmpty else {
      throw AgentFailure(message: "无法确认仓库默认分支，请检查远端地址。")
    }
    // Detached HEAD has no source ref yet. The base is only a metadata snapshot,
    // never a push destination; the workflow captures a separate new-branch plan.
    let plan = try await GitPushService.prepare(at: root, remote: remote,
      destination: destination.isEmpty ? base : destination, forceWithLease: false,
      allowDetached: allowUnpublished)
    let detached = choices.branch.isEmpty
    let existing = detached ? nil : try await existingPR(repository, head: destination, at: root)
    var problem: String?
    var published: String?
    if existing == nil && !detached {
      if destination == base { problem = "请先切换或创建功能分支，再创建 PR。" }
      else if plan.expectedRemoteCommit.isEmpty || plan.expectedRemoteCommit != plan.commit {
        if !allowUnpublished { problem = "请先推送当前分支，再创建 PR。" }
        if !plan.expectedRemoteCommit.isEmpty {
          published = try await remoteCommit(repository, branch: destination, at: root)
        }
      } else {
        published = try await remoteCommit(repository, branch: destination, at: root)
        if published != plan.commit && !allowUnpublished {
          problem = "远端分支与当前提交不一致，请先同步并推送分支。"
        }
      }
    }
    return GitHubPRContext(plan: plan, repository: repository, defaultBranch: base,
      existing: existing, creationProblem: problem, publishedCommit: published,
      allowsLocalPreparation: allowUnpublished)
  }

  func create(_ context: GitHubPRContext, base: String, title: String, body: String, draft: Bool,
    publishedOnly: Bool = false,
    authorize: GitMutationAuthorization = {}) async throws -> GitHubPullRequest {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, title.count <= 256, !title.contains("\n"), !title.contains("\r"), body.utf8.count <= 65_536 else {
      throw AgentFailure(message: "请填写 256 字符以内的单行标题，描述不能超过 64 KiB。")
    }
    let valid = try await LocalWorkspaceService.git(["check-ref-format", "refs/heads/" + base], at: context.plan.root)
    guard valid.status == 0, base != context.head else { throw AgentFailure(message: "请选择有效且不同于源分支的目标分支。") }
    let fresh = try await inspect(at: context.plan.root, remote: context.plan.remote,
      allowUnpublished: publishedOnly)
    guard fresh.plan == context.plan, fresh.repository == context.repository else {
      throw GitHubPRRefreshRequired(message: "分支、提交或远端已改变，请重新检查后再创建 PR。")
    }
    if let existing = fresh.existing { return existing }
    if let problem = fresh.creationProblem { throw AgentFailure(message: problem) }
    if publishedOnly {
      guard let published = context.publishedCommit, fresh.publishedCommit == published else {
        throw GitHubPRRefreshRequired(message: "已发布的源分支已改变，请重新检查。")
      }
    }
    _ = try await remoteCommit(context.repository, branch: base, at: context.plan.root)
    try Task.checkCancellation()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shipios-pr-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: folder) }
    let bodyFile = folder.appendingPathComponent("body.md")
    guard FileManager.default.createFile(atPath: bodyFile.path, contents: Data(body.utf8), attributes: [.posixPermissions: 0o600]) else {
      throw AgentFailure(message: "无法准备 PR 描述。")
    }
    var args = ["pr", "create", "--repo", context.repository.fullName, "--head", context.head,
      "--base", base, "--title", title, "--body-file", bodyFile.path]
    if draft { args.append("--draft") }
    let output: String
    try await authorize()
    do { output = try await run(args, at: context.plan.root) }
    catch { throw GitHubPRRefreshRequired(message: error.localizedDescription) }
    guard let url = output.split(whereSeparator: \.isWhitespace).compactMap({ context.repository.pullRequestURL(String($0)) }).first,
      let number = Int(url.lastPathComponent) else {
      throw GitHubPRRefreshRequired(message: "创建结果尚未确认，请重新检查 PR 状态。")
    }
    return GitHubPullRequest(number: number, url: url.absoluteString, title: title, isDraft: draft,
      headRefName: context.head, baseRefName: base, isCrossRepository: false,
      state: "OPEN", checkedAt: Date())
  }

  static func compareURL(repository: GitHubRepository, base: String, head: String,
    title: String, body: String) throws -> URL {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, title.count <= 256, !title.contains("\n"), !title.contains("\r"),
      body.utf8.count <= 65_536, !base.isEmpty, !head.isEmpty, base != head else {
      throw AgentFailure(message: "请填写有效的源分支、目标分支、单行标题和描述。")
    }
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    guard let basePath = base.addingPercentEncoding(withAllowedCharacters: safe),
      let headPath = head.addingPercentEncoding(withAllowedCharacters: safe) else {
      throw AgentFailure(message: "无法编码 PR 分支名称。")
    }
    var components = URLComponents()
    components.scheme = "https"; components.host = "github.com"
    components.percentEncodedPath = "/" + repository.fullName + "/compare/" + basePath + "..." + headPath
    components.queryItems = [URLQueryItem(name: "expand", value: "1"),
      URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
    // A literal '+' in a URL query must survive form-style query decoding.
    components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    guard let url = components.url, url.absoluteString.utf8.count < 8192 else {
      throw AgentFailure(message: "预填 PR 地址过长，请缩短描述，或选择在应用内创建 PR。")
    }
    return url
  }

  func browserDestination(_ context: GitHubPRContext, base: String, title: String, body: String,
    publishedOnly: Bool, authorize: GitMutationAuthorization) async throws -> GitPullRequestDestination {
    let url = try Self.compareURL(repository: context.repository, base: base, head: context.head,
      title: title, body: body)
    let valid = try await LocalWorkspaceService.git(["check-ref-format", "refs/heads/" + base], at: context.plan.root)
    guard valid.status == 0 else { throw AgentFailure(message: "请选择有效的目标分支。") }
    let fresh = try await inspect(at: context.plan.root, remote: context.plan.remote, allowUnpublished: publishedOnly)
    guard fresh.plan == context.plan, fresh.repository == context.repository else {
      throw GitHubPRRefreshRequired(message: "分支、提交或远端已改变，请重新检查后打开 PR。")
    }
    if let existing = fresh.existing { return .pullRequest(existing) }
    if let problem = fresh.creationProblem { throw AgentFailure(message: problem) }
    if publishedOnly {
      guard let published = context.publishedCommit, fresh.publishedCommit == published else {
        throw GitHubPRRefreshRequired(message: "已发布的源分支已改变，请重新检查。")
      }
    }
    _ = try await remoteCommit(context.repository, branch: base, at: context.plan.root)
    try Task.checkCancellation()
    try await authorize()
    return .browser(url, context: fresh)
  }

  func generationContent(_ context: GitHubPRContext, base: String) async throws -> GitPullRequestContent {
    let valid = try await LocalWorkspaceService.git(["check-ref-format", "refs/heads/" + base], at: context.plan.root)
    guard valid.status == 0, base != context.head else {
      throw AgentFailure(message: "请选择有效且不同于源分支的目标分支。")
    }
    let fresh = try await inspect(at: context.plan.root, remote: context.plan.remote)
    guard fresh == context else {
      throw GitHubPRRefreshRequired(message: "分支、提交或 PR 状态已改变，请重新检查。")
    }
    if let problem = fresh.creationProblem { throw AgentFailure(message: problem) }
    let baseCommit = try await remoteCommit(context.repository, branch: base, at: context.plan.root)
    return try await GitPullRequestContent.capture(context, base: base, baseCommit: baseCommit)
  }

  func details(for pullRequest: GitHubPullRequest, at root: URL) async throws -> GitHubPRDetails {
    guard let url = pullRequest.validatedURL else {
      throw AgentFailure(message: "保存的 PR 地址无效。")
    }
    let parts = url.pathComponents
    guard parts.count == 5 else { throw AgentFailure(message: "无法识别 PR 仓库。") }
    let repository = try GitHubRepository.parse("https://github.com/\(parts[1])/\(parts[2])")
    let output = try await run(["pr", "view", String(pullRequest.number), "--repo",
      repository.fullName, "--json",
      "number,url,title,body,state,isDraft,headRefName,baseRefName,reviewDecision,mergeable,statusCheckRollup,headRefOid,mergeStateStatus"], at: root)
    let details = try JSONDecoder().decode(GitHubPRDetails.self, from: Data(output.utf8))
    guard details.number == pullRequest.number,
      repository.pullRequestURL(details.url) == url,
      ["OPEN", "CLOSED", "MERGED"].contains(details.state.uppercased()) else {
      throw AgentFailure(message: "GitHub 返回的 PR 与当前任务记录不一致。")
    }
    return details
  }

  private func existingPR(_ repository: GitHubRepository, head: String, at root: URL) async throws -> GitHubPullRequest? {
    let output = try await run(["pr", "list", "--repo", repository.fullName, "--head", head, "--state", "open", "--limit", "100",
      "--json", "number,url,title,isDraft,headRefName,baseRefName,isCrossRepository"], at: root)
    let items = try JSONDecoder().decode([GitHubPullRequest].self, from: Data(output.utf8))
    let matches = items.filter { $0.headRefName == head && !$0.isCrossRepository }
    guard matches.count <= 1 else { throw AgentFailure(message: "此分支有多个已打开的 PR，请在 GitHub 中选择。") }
    if var item = matches.first {
      guard let url = repository.pullRequestURL(item.url), Int(url.lastPathComponent) == item.number else {
        throw AgentFailure(message: "GitHub 返回了无效的 PR 地址。")
      }
      item.state = "OPEN"
      item.checkedAt = Date()
      return item
    }
    return nil
  }

  func remoteCommit(_ repository: GitHubRepository, branch: String, at root: URL) async throws -> String {
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    guard let branchPath = branch.addingPercentEncoding(withAllowedCharacters: safe) else {
      throw AgentFailure(message: "无法编码远端分支名称。")
    }
    return try await run(["api", "--hostname", "github.com", "repos/\(repository.fullName)/git/ref/heads/\(branchPath)",
      "--jq", ".object.sha"], at: root).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
