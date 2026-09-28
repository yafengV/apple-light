import Foundation

extension GitHubPRService {
  /// Metadata edits do not depend on a checked-out branch or an unchanged head commit.
  /// GitHub remains the authority for title-edit permission; description requires author + open.
  func edit(_ field: GitHubPREditField, text: String, request: GitHubPullRequest, at root: URL,
    authorize: GitMutationAuthorization = {}) async throws -> GitHubPRMergeSnapshot {
    let value = field == .title ? GitHubPREditText.trimmed(GitHubPREditText.title(text)) : text
    guard field != .title || (!value.isEmpty && value.count <= 256),
      field != .body || value.utf8.count <= 65_536 else {
      throw AgentFailure(message: "请填写 256 字符以内的标题，描述不能超过 64 KiB。")
    }
    try await authorize()
    let fresh = try await mergeSnapshot(for: request, at: root)
    guard field != .body || GitHubPREditText.canEditBody(fresh) else {
      throw GitHubPREditFailure(message: "只有开放 PR 的作者可以编辑描述。", snapshot: fresh)
    }
    // Covers a previous accepted request whose response was lost; never send a blind retry.
    if GitHubPREditText.value(field, in: fresh) == value { return fresh }
    var args = ["pr", "edit", "\(request.number)", "--repo", fresh.repository.fullName]
    var directory: URL?
    defer { if let directory { try? FileManager.default.removeItem(at: directory) } }
    if field == .title { args += ["--title", value] }
    else {
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shipios-pr-edit-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      directory = folder
      let file = folder.appendingPathComponent("body.md")
      guard FileManager.default.createFile(atPath: file.path, contents: Data(value.utf8),
        attributes: [.posixPermissions: 0o600]) else { throw AgentFailure(message: "无法准备 PR 描述。") }
      args += ["--body-file", file.path]
    }
    try await authorize(); try Task.checkCancellation()
    var writeError: Error?
    do { _ = try await run(args, at: root) } catch { writeError = error }
    try Task.checkCancellation()
    let confirmed: GitHubPRMergeSnapshot
    do { confirmed = try await mergeSnapshot(for: request, at: root) }
    catch {
      throw GitHubPREditFailure(message: "保存结果尚未确认，请刷新状态后重试。\n" + (writeError ?? error).localizedDescription,
        snapshot: nil)
    }
    guard GitHubPREditText.value(field, in: confirmed) == value else {
      throw GitHubPREditFailure(message: writeError?.localizedDescription ?? "GitHub 未确认保存内容，请重试。",
        snapshot: confirmed)
    }
    return confirmed
  }

  func generateDescription(request: GitHubPullRequest, expected: GitHubPRMergeSnapshot,
    body: String, instructions: String, at root: URL, generate: GitTextGeneration,
    authorize: GitMutationAuthorization = {}) async throws -> (String, GitHubPRMergeSnapshot) {
    try await authorize()
    let before = try await mergeSnapshot(for: request, at: root)
    guard GitHubPREditText.canEditBody(before), let head = expected.headRevision,
      before.headRevision == head, before.details.baseRefName == expected.details.baseRefName,
      before.details.headRefName == expected.details.headRefName else {
      throw AgentFailure(message: "PR 状态、源提交或目标分支已改变，请刷新后重新生成。")
    }
    let diff = try await run(["pr", "diff", "\(request.number)", "--repo", before.repository.fullName,
      "--color", "never"], at: root)
    // Read after the diff too, so changes during capture never reach the model as the old revision.
    let captured = try await mergeSnapshot(for: request, at: root)
    guard captured.headRevision == head, captured.details.baseRefName == before.details.baseRefName,
      captured.details.headRefName == before.details.headRefName, GitHubPREditText.canEditBody(captured) else {
      throw AgentFailure(message: "PR 在读取差异时发生变化，请刷新后重新生成。")
    }
    try await authorize(); try Task.checkCancellation()
    let text = GitHubPREditText.trimmed(try await generate(PullRequestDescriptionPrompt.messages(
      snapshot: captured, body: body, instructions: instructions, diff: diff)))
    try Task.checkCancellation()
    guard !text.isEmpty, text.utf8.count <= 65_536 else {
      throw AgentFailure(message: "模型未返回有效的 PR 描述，请重试或手动填写。")
    }
    let after = try await mergeSnapshot(for: request, at: root)
    guard after.headRevision == head, after.details.baseRefName == captured.details.baseRefName,
      after.details.headRefName == captured.details.headRefName, GitHubPREditText.canEditBody(after) else {
      throw AgentFailure(message: "PR 在生成期间发生变化，未替换当前草稿。请刷新后重新生成。")
    }
    try await authorize(); try Task.checkCancellation()
    return (text, after)
  }
}
