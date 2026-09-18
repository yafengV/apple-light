import XCTest
@testable import ShipiOS

final class GitPushTests: XCTestCase {
  private func git(_ args: [String], _ root: URL) async throws -> String {
    try await GitReviewService.checked(args, at: root).trimmingCharacters(in: .newlines)
  }
  private func fixture() async throws -> (URL, URL, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let repo = folder.appendingPathComponent("working"), remote = folder.appendingPathComponent("remote.git")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    _ = try await git(["init", "--bare", "-q", "-b", "main"], remote)
    _ = try await git(["init", "-q", "-b", "main"], repo)
    _ = try await git(["config", "user.name", "ShipiOS tests"], repo)
    _ = try await git(["config", "user.email", "test@example.invalid"], repo)
    _ = try await git(["remote", "add", "origin", remote.path], repo)
    _ = try await commit("initial", repo)
    return (folder, repo, remote)
  }
  @discardableResult private func commit(_ content: String, _ repo: URL, amend: Bool = false) async throws -> String {
    try Data(content.utf8).write(to: repo.appendingPathComponent("file.txt"))
    _ = try await git(["add", "--", "file.txt"], repo)
    _ = try await git(["commit", "-q", "-m", content] + (amend ? ["--amend"] : []), repo)
    return try await git(["rev-parse", "HEAD"], repo)
  }
  private func plan(_ repo: URL, force: Bool = false) async throws -> GitPushPlan {
    try await GitPushService.prepare(at: repo, remote: "origin", destination: "main", forceWithLease: force)
  }

  func testFirstPushSetsUpstreamAndOnlyPushesSelectedBranch() async throws {
    let (_, repo, remote) = try await fixture()
    _ = try await git(["branch", "other"], repo)
    _ = try await git(["tag", "not-selected"], repo)
    _ = try await git(["config", "push.followTags", "true"], repo)
    _ = try await git(["config", "remote.origin.push", "refs/heads/*:refs/heads/*"], repo)
    _ = try await git(["config", "remote.origin.mirror", "true"], repo)
    let choices = try await GitPushService.choices(at: repo)
    XCTAssertEqual(choices.preferredRemote, "origin")
    XCTAssertEqual(choices.preferredDestination, "main")
    let first = try await plan(repo)
    let warning = try await GitPushService.push(first)
    XCTAssertNil(warning)
    let remoteHead = try await git(["rev-parse", "refs/heads/main"], remote)
    XCTAssertEqual(remoteHead, first.commit)
    let refs = try await git(["for-each-ref", "--format=%(refname)"], remote)
    XCTAssertEqual(refs, "refs/heads/main")
    let upstream = try await git(["rev-parse", "--abbrev-ref", "@{upstream}"], repo)
    XCTAssertEqual(upstream, "origin/main")
    let next = try await commit("next", repo)
    _ = try await GitPushService.push(plan(repo))
    let remoteNext = try await git(["rev-parse", "refs/heads/main"], remote)
    XCTAssertEqual(remoteNext, next)
  }

  func testLeaseAllowsKnownRewriteAndRejectsUnseenRemoteCommit() async throws {
    let (folder, repo, remote) = try await fixture()
    _ = try await GitPushService.push(plan(repo))
    let amended = try await commit("amended", repo, amend: true)
    do { _ = try await GitPushService.push(plan(repo)); XCTFail("non-fast-forward must fail") }
    catch { XCTAssertTrue(error.localizedDescription.contains("rejected")) }
    _ = try await GitPushService.push(plan(repo, force: true))
    let remoteAmended = try await git(["rev-parse", "refs/heads/main"], remote)
    XCTAssertEqual(remoteAmended, amended)
    let other = folder.appendingPathComponent("other")
    _ = try await git(["clone", "-q", remote.path, other.path], folder)
    _ = try await git(["config", "user.name", "Other"], other)
    _ = try await git(["config", "user.email", "other@example.invalid"], other)
    let unseen = try await commit("unseen", other)
    _ = try await git(["push", "origin", "main"], other)
    _ = try await commit("another rewrite", repo, amend: true)
    do { _ = try await GitPushService.push(plan(repo, force: true)); XCTFail("lease must reject unseen update") }
    catch { XCTAssertTrue(error.localizedDescription.contains("stale info")) }
    let stillUnseen = try await git(["rev-parse", "refs/heads/main"], remote)
    XCTAssertEqual(stillUnseen, unseen)
  }

  func testChangedHeadOrRemoteRejectsCapturedPlan() async throws {
    let (_, repo, remote) = try await fixture()
    let previous = try await plan(repo)
    _ = try await commit("changed", repo)
    do { _ = try await GitPushService.push(previous); XCTFail("must reject changed HEAD") }
    catch { XCTAssertTrue(error.localizedDescription.contains("已改变")) }
    let current = try await plan(repo)
    _ = try await git(["remote", "set-url", "--push", "origin", remote.appendingPathComponent("different").path], repo)
    do { _ = try await GitPushService.push(current); XCTFail("must reject changed destination") }
    catch { XCTAssertTrue(error.localizedDescription.contains("已改变")) }
    let refs = try await git(["for-each-ref", "--format=%(refname)"], remote)
    XCTAssertTrue(refs.isEmpty)
  }

  func testPushDefaultsAndTrackingRefspecs() async throws {
    let (_, repo, remote) = try await fixture()
    _ = try await git(["remote", "add", "fork", remote.path], repo)
    _ = try await git(["config", "branch.main.remote", "origin"], repo)
    _ = try await git(["config", "branch.main.merge", "refs/heads/review"], repo)
    var choices = try await GitPushService.choices(at: repo)
    XCTAssertEqual(choices.preferredDestination, "review")
    _ = try await git(["config", "branch.main.pushRemote", "fork"], repo)
    choices = try await GitPushService.choices(at: repo)
    XCTAssertEqual(choices.preferredRemote, "fork")
    XCTAssertEqual(choices.preferredDestination, "main")
    XCTAssertEqual(try GitPushService.trackingReference(for: "refs/heads/main",
      refspecs: "+refs/heads/*:refs/remotes/custom/*"), "refs/remotes/custom/main")
    XCTAssertNil(try GitPushService.trackingReference(for: "refs/heads/private/topic",
      refspecs: "+refs/heads/*:refs/remotes/custom/*\n^refs/heads/private/*"))
    XCTAssertThrowsError(try GitPushService.trackingReference(for: "refs/heads/main",
      refspecs: "+refs/heads/*:refs/remotes/a/*\n+refs/heads/*:refs/remotes/b/*"))
  }

  @MainActor func testWorkspacePushFailureKeepsCommitDraftAndReportsError() async throws {
    let (_, repo, remote) = try await fixture()
    let workspace = DeveloperWorkspace()
    workspace.root = repo
    await workspace.refreshGit()
    workspace.commitMessage = "preserved draft"
    _ = try await git(["remote", "set-url", "origin", remote.appendingPathComponent("missing").path], repo)
    let success = await workspace.push(remote: "origin", destination: "main", forceWithLease: false)
    XCTAssertFalse(success)
    XCTAssertFalse(workspace.gitBusy)
    XCTAssertNil(workspace.pushOperation)
    XCTAssertNotNil(workspace.error)
    XCTAssertEqual(workspace.commitMessage, "preserved draft")
    let preferences = try JSONDecoder().decode(GitPreferences.self, from: Data("{}".utf8))
    XCTAssertFalse(preferences.alwaysForcePush)
    var updated = preferences
    updated.alwaysForcePush = true
    XCTAssertTrue(try JSONDecoder().decode(GitPreferences.self, from: JSONEncoder().encode(updated)).alwaysForcePush)
    XCTAssertTrue(SettingsSearch.results(for: "force-with-lease").contains { $0.field == .alwaysForcePush })
  }

  func testInvalidAndDetachedAndMultiplePushURLsAreRejected() async throws {
    let (_, repo, remote) = try await fixture()
    do {
      _ = try await GitPushService.prepare(at: repo, remote: "origin", destination: "../wrong", forceWithLease: false)
      XCTFail("invalid ref must fail")
    } catch { XCTAssertTrue(error.localizedDescription.contains("名称无效")) }
    _ = try await git(["remote", "set-url", "--add", "--push", "origin", remote.path], repo)
    _ = try await git(["remote", "set-url", "--add", "--push", "origin", remote.appendingPathComponent("second").path], repo)
    do { _ = try await plan(repo); XCTFail("must reject multiple targets") }
    catch { XCTAssertTrue(error.localizedDescription.contains("多个")) }
    _ = try await git(["checkout", "--detach", "-q"], repo)
    do { _ = try await GitPushService.choices(at: repo); XCTFail("detached HEAD must fail") }
    catch { XCTAssertTrue(error.localizedDescription.contains("本地分支")) }
  }

  @MainActor func testCommitAndPushFailureCanRetryPushWithoutDuplicateCommit() async throws {
    let (folder, repo, remote) = try await fixture()
    let store = WorkspaceStore(dataRoot: folder.appendingPathComponent("settings"))
    let workspace = DeveloperWorkspace()
    workspace.root = repo
    try Data("second".utf8).write(to: repo.appendingPathComponent("file.txt"))
    _ = try await git(["add", "file.txt"], repo)
    await workspace.refreshGit()
    workspace.commitMessage = "Second commit"
    _ = try await git(["remote", "set-url", "origin", remote.appendingPathComponent("missing").path], repo)
    let failed = await store.performGitAction(.commitAndPush, in: workspace, remote: "origin", destination: "main")
    XCTAssertFalse(failed)
    XCTAssertNotNil(workspace.error)
    XCTAssertTrue(workspace.gitActionStatus?.contains("已提交") == true)
    XCTAssertEqual(workspace.commitMessage, "")
    XCTAssertFalse(workspace.gitActionRunning)
    XCTAssertFalse(workspace.gitBusy)
    let count = try await git(["rev-list", "--count", "HEAD"], repo)
    XCTAssertEqual(count, "2")
    _ = try await git(["remote", "set-url", "origin", remote.path], repo)
    let retried = await store.performGitAction(.push, in: workspace, remote: "origin", destination: "main")
    XCTAssertTrue(retried)
    XCTAssertNil(workspace.error)
    let afterCount = try await git(["rev-list", "--count", "HEAD"], repo)
    XCTAssertEqual(afterCount, "2")
    let localHead = try await git(["rev-parse", "HEAD"], repo)
    let remoteHead = try await git(["rev-parse", "refs/heads/main"], remote)
    XCTAssertEqual(localHead, remoteHead)
    store.library.gitPreferences.readOnlyReview = true
    let blocked = await store.performGitAction(.push, in: workspace, remote: "origin", destination: "main")
    XCTAssertFalse(blocked)
  }

  @MainActor func testUnbornRepositoryCanCommitAndPushFromSameAction() async throws {
    let (folder, repo, remote) = try await fixture()
    _ = try await git(["checkout", "--orphan", "new-branch"], repo)
    let choices = try await GitPushService.choices(at: repo)
    XCTAssertFalse(choices.hasCommit)
    XCTAssertEqual(choices.preferredDestination, "new-branch")
    let store = WorkspaceStore(dataRoot: folder.appendingPathComponent("settings"))
    let workspace = DeveloperWorkspace()
    workspace.root = repo
    await workspace.refreshGit()
    workspace.commitMessage = "First commit on new branch"
    let success = await store.performGitAction(.commitAndPush, in: workspace,
      remote: choices.preferredRemote, destination: choices.preferredDestination)
    XCTAssertTrue(success, workspace.error ?? "")
    let ref = try await git(["rev-parse", "refs/heads/new-branch"], remote)
    let local = try await git(["rev-parse", "HEAD"], repo)
    XCTAssertEqual(ref, local)
  }
}
