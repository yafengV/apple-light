import Foundation

struct GitPushPlan: Equatable, Sendable {
  let root: URL
  let branch: String
  let commit: String
  let remote: String
  let destination: String
  let pushURL: String
  let trackingReference: String?
  let expectedRemoteCommit: String
  let forceWithLease: Bool
}

struct GitPushChoices: Sendable {
  let branch: String
  var hasCommit: Bool
  let remotes: [String]
  let preferredRemote: String
  let preferredDestination: String
}

enum GitPushService {
  static func choices(at root: URL) async throws -> GitPushChoices {
    let snapshot = try await GitBranchService.snapshot(at: root)
    guard snapshot.canChange, let reference = snapshot.currentReference else {
      throw AgentFailure(message: "请在仓库根目录选择本地分支后推送。")
    }
    let branch = String(reference.dropFirst("refs/heads/".count))
    let remotes = try await GitReviewService.checked(["remote"], at: root)
      .split(separator: "\n").map(String.init)
    guard !remotes.isEmpty else { throw AgentFailure(message: "尚未配置远端，请先在终端添加 Git remote。") }
    let upstreamRemote = try await config("branch.\(branch).remote", at: root)
    let pushRemote = try await config("branch.\(branch).pushRemote", at: root)
    let pushDefault = try await config("remote.pushDefault", at: root)
    let preferred = [pushRemote, pushDefault, upstreamRemote, "origin", remotes.first ?? ""]
      .first(where: { remotes.contains($0) }) ?? remotes[0]
    let merge = try await config("branch.\(branch).merge", at: root)
    let destination = preferred == upstreamRemote && merge.hasPrefix("refs/heads/")
      ? String(merge.dropFirst("refs/heads/".count)) : branch
    return GitPushChoices(branch: branch, hasCommit: snapshot.currentCommit != nil, remotes: remotes,
      preferredRemote: preferred, preferredDestination: destination)
  }

  static func prepare(at root: URL, remote: String, destination: String,
    forceWithLease: Bool) async throws -> GitPushPlan {
    let choices = try await choices(at: root)
    guard choices.hasCommit else { throw AgentFailure(message: "请先完成首次提交，再推送分支。") }
    guard choices.remotes.contains(remote), !remote.hasPrefix("-") else {
      throw AgentFailure(message: "所选远端已移除，请刷新后重试。")
    }
    let ref = "refs/heads/" + destination
    let valid = try await LocalWorkspaceService.git(["check-ref-format", ref], at: root)
    guard valid.status == 0 else { throw AgentFailure(message: "远端分支名称无效。") }
    let urls = try await GitReviewService.checked(["remote", "get-url", "--push", "--all", remote], at: root)
      .split(separator: "\n").map(String.init)
    guard urls.count == 1 else {
      throw AgentFailure(message: "此远端配置了多个推送地址，请在终端选择地址后推送。")
    }
    let fetch = try await LocalWorkspaceService.git(["config", "--get-all", "remote.\(remote).fetch"], at: root)
    let tracking = try trackingReference(for: ref, refspecs: fetch.status == 0 ? fetch.text : "")
    let expected: String
    if let tracking {
      let value = try await LocalWorkspaceService.git(["rev-parse", "--verify", tracking], at: root)
      expected = value.status == 0 ? value.text.trimmingCharacters(in: .newlines) : ""
    } else {
      guard !forceWithLease else {
        throw AgentFailure(message: "无法确定远端跟踪引用，不能使用强制推送。请检查 remote fetch 配置。")
      }
      expected = ""
    }
    let commit = try await GitReviewService.checked(["rev-parse", "--verify", "HEAD^{commit}"], at: root)
      .trimmingCharacters(in: .newlines)
    return GitPushPlan(root: root, branch: choices.branch, commit: commit, remote: remote,
      destination: ref, pushURL: urls[0], trackingReference: tracking,
      expectedRemoteCommit: expected, forceWithLease: forceWithLease)
  }

  /// Push an immutable commit with a lease captured before execution. No fetch can silently widen it.
  static func push(_ plan: GitPushPlan) async throws -> String? {
    guard try await prepare(at: plan.root, remote: plan.remote,
      destination: String(plan.destination.dropFirst("refs/heads/".count)),
      forceWithLease: plan.forceWithLease) == plan else {
      throw AgentFailure(message: "分支、提交或远端配置已改变，请刷新后重新推送。")
    }
    try Task.checkCancellation()
    var arguments = ["-c", "remote.\(plan.remote).mirror=false", "push", "--porcelain",
      "--no-follow-tags", "--recurse-submodules=no"]
    if plan.forceWithLease {
      arguments.append("--force-with-lease=\(plan.destination):\(plan.expectedRemoteCommit)")
    }
    arguments += ["--", plan.remote, "\(plan.commit):\(plan.destination)"]
    _ = try await GitReviewService.checked(arguments, at: plan.root)
    // Git updates the matching remote-tracking reference even with an object-id source.
    // Only establish tracking while the same local branch still denotes the pushed commit.
    let head = try await LocalWorkspaceService.git(["symbolic-ref", "-q", "HEAD"], at: plan.root)
    let commit = try await LocalWorkspaceService.git(["rev-parse", "HEAD"], at: plan.root)
    guard head.text.trimmingCharacters(in: .newlines) == "refs/heads/" + plan.branch,
      commit.text.trimmingCharacters(in: .newlines) == plan.commit else {
      return "推送成功；本地分支已变化，未修改其跟踪设置。"
    }
    // Preserve triangular workflows and existing upstreams.
    let upstream = try await config("branch.\(plan.branch).remote", at: plan.root)
    if upstream.isEmpty, let tracking = plan.trackingReference {
      let result = try await LocalWorkspaceService.git(
        ["branch", "--set-upstream-to=" + tracking, "--", plan.branch], at: plan.root)
      if result.status != 0 { return "推送成功，但未能设置上游分支：" + result.text }
    }
    return nil
  }

  private static func config(_ key: String, at root: URL) async throws -> String {
    let value = try await LocalWorkspaceService.git(["config", "--get", key], at: root)
    return value.status == 0 ? value.text.trimmingCharacters(in: .newlines) : ""
  }

  static func trackingReference(for ref: String, refspecs: String) throws -> String? {
    func match(_ pattern: String) -> String? {
      let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
      if parts.count == 1 { return ref == pattern ? "" : nil }
      guard parts.count == 2, ref.hasPrefix(parts[0]), ref.hasSuffix(parts[1]),
        ref.count >= parts[0].count + parts[1].count else { return nil }
      return String(ref.dropFirst(parts[0].count).dropLast(parts[1].count))
    }
    var matches = Set<String>()
    for line in refspecs.split(separator: "\n").map(String.init) {
      if line.hasPrefix("^") {
        if match(String(line.dropFirst())) != nil { return nil }
        continue
      }
      let fields = (line.hasPrefix("+") ? String(line.dropFirst()) : line)
        .split(separator: ":", omittingEmptySubsequences: false).map(String.init)
      guard fields.count == 2, let wildcard = match(fields[0]) else { continue }
      let target = fields[1].replacingOccurrences(of: "*", with: wildcard)
      guard target.hasPrefix("refs/remotes/"), !target.contains("*") else {
        throw AgentFailure(message: "远端跟踪引用配置不受支持。")
      }
      matches.insert(target)
    }
    guard matches.count <= 1 else { throw AgentFailure(message: "远端跟踪引用配置存在歧义。") }
    return matches.first
  }
}
