import Foundation

extension GitHubPRService {
  func postInlineComment(_ body: String, anchor: GitHubPRInlineAnchor, fresh: GitHubPRDiscussionSnapshot,
    request: GitHubPullRequest, at root: URL, authorize: GitMutationAuthorization) async throws -> GitHubPRDiscussionResult {
    guard fresh.nodeID == anchor.identity.nodeID, fresh.head.lowercased() == anchor.identity.head.lowercased(),
      let url = request.validatedURL else {
      throw GitHubPRDiscussionFailure(message: "PR 版本已改变，原代码评论草稿已保留。请重新选择代码行。", snapshot: fresh, staleInline: anchor)
    }
    let codeRequest = GitHubPRCodeRequest(taskID: "inline-validation", root: root, pullRequest: request, head: anchor.identity.head)
    let code: GitHubPRCodeSnapshot
    do { code = try await codeSnapshot(codeRequest) }
    catch let error as GitHubPRCodeChanged {
      throw GitHubPRDiscussionFailure(message: error.localizedDescription, snapshot: fresh, staleInline: anchor)
    }
    guard anchor.matches(code) else {
      throw GitHubPRDiscussionFailure(message: "PR 差异已改变，不能把原草稿提交到新代码行。", snapshot: fresh, staleInline: anchor)
    }
    // The final identity read guards drift during preparation. commit_id binds the write
    // to the selected revision; GitHub does not provide an atomic head-match REST flag.
    guard try await codeIdentity(codeRequest) == anchor.identity else {
      throw GitHubPRDiscussionFailure(message: "PR 代码版本已改变，请刷新后重新选择。", snapshot: fresh, staleInline: anchor)
    }
    try Task.checkCancellation(); try await authorize()
    let text = JavaScriptText.trimmed(body), position = anchor.position
    var input: [String: JSONValue] = ["body": .string(text), "commit_id": .string(anchor.identity.head),
      "path": .string(position.path), "side": .string(position.side.rawValue.uppercased()), "line": .number(Double(position.line))]
    if let start = position.startLine {
      input["start_line"] = .number(Double(start))
      input["start_side"] = .string((position.startSide ?? position.side).rawValue.uppercased())
    }
    let endpoint = "repos/" + url.pathComponents[1] + "/" + url.pathComponents[2] + "/pulls/" + String(request.number) + "/comments"
    let action = GitHubPRDiscussionAction.inline(body: body, anchor: anchor)
    let attempt = GitHubPRDiscussionAttempt(action: action, baseline: fresh)
    var receipt: JSONValue?, writeError: Error?, rejected = false
    do {
      let output = try await inlineREST(endpoint, input: input, at: root)
      let response = Self.inlineResponse(output.text)
      rejected = response.status.map { (400..<500).contains($0) } ?? false
      if output.status == 0, response.status == 201,
        let node = response.body, Self.inlineReceiptConfirms(node, body: text, anchor: anchor, baseline: fresh, request: request) {
        receipt = node
      } else {
        writeError = AgentFailure(message: rejected ? "GitHub 拒绝了代码评论（HTTP \(response.status ?? 0)）。请检查权限和所选范围后重试。"
          : "未能确认 GitHub 是否接受代码评论，请重新读取结果。")
      }
    } catch { writeError = error; rejected = error is GitHubPRDiscussionRejected }
    try Task.checkCancellation()
    var current: GitHubPRDiscussionSnapshot?
    var readError: Error?
    do {
      let result = try await discussion(for: request, at: root)
      guard result.nodeID == fresh.nodeID, result.viewer.lowercased() == fresh.viewer.lowercased(),
        result.requestURL.lowercased() == fresh.requestURL.lowercased() else {
        throw AgentFailure(message: "PR 或 GitHub 账户在操作后发生变化。")
      }
      current = result
      if Self.inlineConfirmed(body, anchor: anchor, baseline: fresh, current: result) { return .init(snapshot: result) }
    } catch is CancellationError { throw CancellationError() }
    catch { readError = error }
    if receipt != nil {
      // A REST comment ID is not a GraphQL review-thread ID. Do not fabricate a
      // reply/resolve target while the thread connection is still unavailable.
      return .init(snapshot: current ?? fresh, notice: "GitHub 已接受代码评论，" + (readError == nil ? "评论列表稍后会重新读取。" : "但评论刷新失败，请重新读取。"))
    }
    throw GitHubPRDiscussionFailure(message: writeError?.localizedDescription ?? readError?.localizedDescription ?? "代码评论结果尚未确认。",
      snapshot: current ?? fresh, uncertain: rejected ? nil : attempt)
  }

  private func inlineREST(_ endpoint: String, input: [String: JSONValue], at root: URL) async throws -> CommandOutput {
    guard let executable = executable ?? Self.installedExecutable(), FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw GitHubPRDiscussionRejected(message: "尚未安装 GitHub CLI。")
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shipios-pr-inline-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("input.json")
    guard FileManager.default.createFile(atPath: file.path, contents: try JSONEncoder().encode(JSONValue.object(input)),
      attributes: [.posixPermissions: 0o600]) else { throw GitHubPRDiscussionRejected(message: "无法准备代码评论请求。") }
    return try await LocalWorkspaceService.command(executable.path,
      ["api", endpoint, "--hostname", "github.com", "--method", "POST", "--include", "--input", file.path], at: root)
  }

  static func inlineResponse(_ output: String) -> (status: Int?, body: JSONValue?) {
    let source = output.replacingOccurrences(of: "\r\n", with: "\n")
    let first = source.components(separatedBy: "\n").first ?? ""
    guard first.hasPrefix("HTTP/"), let status = first.split(separator: " ").dropFirst().first.flatMap({ Int($0) }),
      let boundary = source.range(of: "\n\n") else { return (nil, nil) }
    return (status, try? JSONDecoder().decode(JSONValue.self, from: Data(source[boundary.upperBound...].utf8)))
  }

  static func inlineConfirmed(_ body: String, anchor: GitHubPRInlineAnchor, baseline: GitHubPRDiscussionSnapshot,
    current: GitHubPRDiscussionSnapshot) -> Bool {
    current.threads.filter { thread in
      guard let root = thread.comments.first, !baseline.commentIDs.contains(root.id), root.kind == .code,
        root.author.lowercased() == baseline.viewer.lowercased(), root.body == JavaScriptText.trimmed(body) else { return false }
      let commit = anchor.identity.head.lowercased()
      return root.commit?.lowercased() == commit && sameInlinePosition(thread.position, anchor.position)
        || (root.originalCommit ?? root.commit)?.lowercased() == commit && sameInlinePosition(thread.hunkPosition, anchor.position)
    }.count == 1
  }
  static func sameInlinePosition(_ first: GitHubPRCommentPosition?, _ second: GitHubPRCommentPosition) -> Bool {
    guard let first else { return false }
    return first.path == second.path && first.side == second.side && first.line == second.line
      && (first.startLine ?? first.line) == (second.startLine ?? second.line)
      && (first.startSide ?? first.side) == (second.startSide ?? second.side)
  }
  private static func inlineReceiptConfirms(_ node: JSONValue, body: String, anchor: GitHubPRInlineAnchor,
    baseline: GitHubPRDiscussionSnapshot, request: GitHubPullRequest) -> Bool {
    let point = anchor.position
    guard let id = node["node_id"].text, !id.isEmpty, !baseline.commentIDs.contains(id),
      node["body"].text == body, node["user"]["login"].text?.lowercased() == baseline.viewer.lowercased(),
      node["commit_id"].text?.lowercased() == anchor.identity.head.lowercased(), node["path"].text == point.path,
      node["line"].int == point.line, node["side"].text == point.side.rawValue.uppercased(),
      node["in_reply_to_id"] == .null, let url = request.validatedURL,
      node["pull_request_url"].text?.lowercased() == ("https://api.github.com/repos/" + url.pathComponents[1] + "/" + url.pathComponents[2] + "/pulls/" + String(request.number)).lowercased() else { return false }
    let position = GitHubPRCommentPosition(path: point.path, line: point.line, side: point.side,
      startLine: node["start_line"].int, startSide: .init(apiValue: node["start_side"].text))
    return sameInlinePosition(position, point)
  }
}
