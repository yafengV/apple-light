import XCTest
@testable import ShipiOS

final class GitPullRequestWorkflowTests: XCTestCase {
  struct Fixture {
    let root: URL
    let remote: URL
    let service: GitHubPRService
    let base: String
    let head: String
  }

  private func git(_ args: [String], at root: URL) async throws -> String {
    try await GitReviewService.checked(args, at: root).trimmingCharacters(in: .newlines)
  }
  private func write(_ value: String, _ name: String = "file.txt", in fixture: Fixture) throws {
    try Data(value.utf8).write(to: fixture.root.appendingPathComponent(name))
  }
  private func fixture(published: Bool = true) async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    _ = try await git(["init", "-q", "-b", "main"], at: root)
    _ = try await git(["config", "user.name", "Workflow test"], at: root)
    _ = try await git(["config", "user.email", "test@example.invalid"], at: root)
    try Data("base\n".utf8).write(to: root.appendingPathComponent("file.txt"))
    _ = try await git(["add", "file.txt"], at: root)
    _ = try await git(["commit", "-qm", "Base"], at: root)
    let base = try await git(["rev-parse", "HEAD"], at: root)
    _ = try await git(["switch", "-qc", "feature/topic"], at: root)
    try Data("published feature\n".utf8).write(to: root.appendingPathComponent("file.txt"))
    _ = try await git(["commit", "-qam", "Published feature"], at: root)
    let head = try await git(["rev-parse", "HEAD"], at: root)
    let remote = root.appendingPathComponent(".git/remote.git")
    try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
    _ = try await git(["init", "--bare", "-q", "-b", "main"], at: remote)
    _ = try await git(["push", remote.path, "main"] + (published ? ["feature/topic"] : []), at: root)
    _ = try await git(["remote", "add", "origin", "git@github.com:sample/project.git"], at: root)
    _ = try await git(["update-ref", "refs/remotes/origin/main", base], at: root)
    if published {
      _ = try await git(["update-ref", "refs/remotes/origin/feature/topic", head], at: root)
      _ = try await git(["branch", "--set-upstream-to=origin/feature/topic"], at: root)
    }
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures")
    let executable = root.appendingPathComponent(".git/gh-fixture")
    let transport = root.appendingPathComponent(".git/ssh-fixture.py")
    try FileManager.default.copyItem(at: sources.appendingPathComponent("github_cli.py"), to: executable)
    try FileManager.default.copyItem(at: sources.appendingPathComponent("github_git_transport.py"), to: transport)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    _ = try await git(["config", "core.sshCommand", "/usr/bin/python3 " + transport.path], at: root)
    _ = try await git(["config", "ssh.variant", "ssh"], at: root)
    let state: [String: Any] = ["head": head, "base": base, "remotePath": remote.path]
    try JSONSerialization.data(withJSONObject: state).write(to: root.appendingPathComponent(".git/github-fixture.json"))
    return Fixture(root: root, remote: remote, service: GitHubPRService(executable: executable), base: base, head: head)
  }

  @MainActor private func workspace(_ fixture: Fixture) async -> (WorkspaceStore, DeveloperWorkspace) {
    let store = WorkspaceStore(dataRoot: fixture.root.appendingPathComponent(".git/app-state"))
    store.libraryLoaded = true
    store.library.tasks = [WorkspaceTask(id: "owner", project: fixture.root.path, title: "Owner", runIDs: []),
      WorkspaceTask(id: "other", project: fixture.root.path, title: "Other", runIDs: [])]
    let workspace = store.workspace
    workspace.root = fixture.root
    store.bindGitReviewPolicy(to: workspace)
    await workspace.refreshGit()
    workspace.pullRequestDraft = GitHubPRDraft(service: fixture.service)
    await workspace.pullRequestDraft.load(at: fixture.root, allowUnpublished: true)
    workspace.pullRequestDraft.title = "Manual title"
    workspace.pullRequestDraft.body = "Manual description\n\n`$(literal)` 中文"
    workspace.commitMessage = "Local changes"
    return (store, workspace)
  }
  private func creates(_ fixture: Fixture) throws -> [[String: Any]] {
    let file = fixture.root.appendingPathComponent(".git/github-requests.jsonl")
    return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").compactMap {
      let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
      return (value["args"] as? [String])?.prefix(2) == ["pr", "create"] ? value : nil
    }
  }
  private func hook(_ name: String, at root: URL, contents: String) throws -> URL {
    let path = root.appendingPathComponent("hooks/" + name)
    try Data(contents.utf8).write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
    return path
  }

  @MainActor func testCommitsStagedUnstagedAndUntrackedThenPushesAndRecordsOwningTask() async throws {
    let fixture = try await fixture()
    try write("staged version\n", in: fixture)
    _ = try await git(["add", "file.txt"], at: fixture.root)
    try write("final local version\n", in: fixture)
    try write("new file\n", "new file.txt", in: fixture)
    let (store, workspace) = await workspace(fixture)
    await store.createPullRequest(in: workspace, draft: true, taskID: "owner")
    XCTAssertNil(workspace.pullRequestDraft.error)
    XCTAssertEqual(workspace.pullRequestDraft.existing?.isDraft, true)
    let count = try await git(["rev-list", "--count", "HEAD"], at: fixture.root)
    XCTAssertEqual(count, "3")
    let text = try await git(["show", "HEAD:file.txt"], at: fixture.root)
    XCTAssertEqual(text, "final local version")
    let new = try await git(["show", "HEAD:new file.txt"], at: fixture.root)
    XCTAssertEqual(new, "new file")
    let remote = try await git(["rev-parse", "refs/heads/feature/topic"], at: fixture.remote)
    let local = try await git(["rev-parse", "HEAD"], at: fixture.root)
    XCTAssertEqual(remote, local)
    XCTAssertEqual(try creates(fixture).count, 1)
    XCTAssertEqual(store.library.taskPullRequests["owner"]?.count, 1)
    XCTAssertNil(store.library.taskPullRequests["other"])
    XCTAssertEqual(workspace.commitMessage, "")
    XCTAssertFalse(workspace.gitBusy)
    XCTAssertFalse(workspace.gitActionRunning)
    XCTAssertEqual(workspace.pullRequestDraft.phase, "")
  }

  @MainActor func testUnpublishedCleanBranchPushesWithoutCreatingAnotherCommit() async throws {
    let fixture = try await fixture(published: false)
    let (store, workspace) = await workspace(fixture)
    workspace.commitMessage = ""
    XCTAssertTrue(workspace.pullRequestDraft.canCreate)
    await store.createPullRequest(in: workspace, draft: false)
    XCTAssertNil(workspace.pullRequestDraft.error)
    let remote = try await git(["rev-parse", "refs/heads/feature/topic"], at: fixture.remote)
    XCTAssertEqual(remote, fixture.head)
    let count = try await git(["rev-list", "--count", "HEAD"], at: fixture.root)
    XCTAssertEqual(count, "2")
    let tracking = try await git(["rev-parse", "--abbrev-ref", "@{upstream}"], at: fixture.root)
    XCTAssertEqual(tracking, "origin/feature/topic")
    XCTAssertEqual(try creates(fixture).count, 1)
  }

  @MainActor func testUncheckedCreatesFromPublishedBranchWithoutStagingCommittingOrPushing() async throws {
    let fixture = try await fixture()
    try write("unpushed commit\n", in: fixture)
    _ = try await git(["commit", "-qam", "Unpushed"], at: fixture.root)
    try write("staged draft\n", in: fixture)
    _ = try await git(["add", "file.txt"], at: fixture.root)
    try write("unstaged draft\n", in: fixture)
    try write("untracked\n", "untracked.txt", in: fixture)
    let (store, workspace) = await workspace(fixture)
    let index = try Data(contentsOf: fixture.root.appendingPathComponent(".git/index"))
    let head = try await git(["rev-parse", "HEAD"], at: fixture.root)
    workspace.pullRequestDraft.includeLocalChanges = false
    await store.createPullRequest(in: workspace, draft: false)
    XCTAssertNil(workspace.pullRequestDraft.error)
    let local = try await git(["rev-parse", "HEAD"], at: fixture.root)
    let remote = try await git(["rev-parse", "refs/heads/feature/topic"], at: fixture.remote)
    XCTAssertEqual(local, head)
    XCTAssertEqual(remote, fixture.head)
    XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(".git/index")), index)
    XCTAssertEqual(workspace.commitMessage, "Local changes")
    XCTAssertEqual(try creates(fixture).count, 1)
  }

  @MainActor func testUncheckedUnpublishedBranchIsBlockedAndCanBeReenabled() async throws {
    let fixture = try await fixture(published: false)
    let (store, workspace) = await workspace(fixture)
    workspace.pullRequestDraft.includeLocalChanges = false
    XCTAssertFalse(workspace.pullRequestDraft.canCreate)
    await store.createPullRequest(in: workspace, draft: false)
    XCTAssertEqual(try creates(fixture).count, 0)
    workspace.pullRequestDraft.includeLocalChanges = true
    XCTAssertTrue(workspace.pullRequestDraft.canCreate)
  }

  @MainActor func testPushFailureRetainsCommitAndManualPRInputThenRetryDoesNotDuplicateCommit() async throws {
    let fixture = try await fixture()
    let rejection = try hook("pre-receive", at: fixture.remote, contents: "#!/bin/sh\necho 'fixture rejects push' >&2\nexit 1\n")
    try write("local change\n", in: fixture)
    let (store, workspace) = await workspace(fixture)
    let body = workspace.pullRequestDraft.body
    await store.createPullRequest(in: workspace, draft: true)
    XCTAssertNotNil(workspace.pullRequestDraft.error)
    XCTAssertNil(workspace.pullRequestDraft.existing)
    XCTAssertEqual(workspace.pullRequestDraft.title, "Manual title")
    XCTAssertEqual(workspace.pullRequestDraft.body, body)
    XCTAssertEqual(workspace.commitMessage, "")
    XCTAssertTrue(workspace.gitActionStatus?.contains("已提交") == true)
    XCTAssertFalse(workspace.gitBusy)
    XCTAssertFalse(workspace.gitActionRunning)
    let committed = try await git(["rev-parse", "HEAD"], at: fixture.root)
    XCTAssertEqual(workspace.pullRequestDraft.context?.plan.commit, committed)
    XCTAssertTrue(workspace.pullRequestDraft.canCreate)
    XCTAssertEqual(try creates(fixture).count, 0)
    try FileManager.default.removeItem(at: rejection)
    await store.createPullRequest(in: workspace, draft: true)
    XCTAssertNil(workspace.pullRequestDraft.error)
    let after = try await git(["rev-parse", "HEAD"], at: fixture.root)
    let count = try await git(["rev-list", "--count", "HEAD"], at: fixture.root)
    XCTAssertEqual(after, committed)
    XCTAssertEqual(count, "3")
    XCTAssertEqual(try creates(fixture).count, 1)
  }

  @MainActor func testCommitHookFailurePreservesMessageAndPRInputForRetry() async throws {
    let fixture = try await fixture()
    let rejection = try hook("pre-commit", at: fixture.root.appendingPathComponent(".git"),
      contents: "#!/bin/sh\necho 'fixture rejects commit' >&2\nexit 1\n")
    try write("local change\n", in: fixture)
    let (store, workspace) = await workspace(fixture)
    await store.createPullRequest(in: workspace, draft: false)
    XCTAssertNotNil(workspace.pullRequestDraft.error)
    XCTAssertEqual(workspace.commitMessage, "Local changes")
    XCTAssertEqual(workspace.pullRequestDraft.title, "Manual title")
    let head = try await git(["rev-parse", "HEAD"], at: fixture.root)
    XCTAssertEqual(head, fixture.head)
    XCTAssertEqual(try creates(fixture).count, 0)
    try FileManager.default.removeItem(at: rejection)
    await store.createPullRequest(in: workspace, draft: false)
    XCTAssertNil(workspace.pullRequestDraft.error)
    XCTAssertEqual(try creates(fixture).count, 1)
  }

  @MainActor func testWorkingFileChangesDuringGenerationDoesNotStageCommitPushOrPublish() async throws {
    let fixture = try await fixture()
    try write("selected local change\n", in: fixture)
    let (_, workspace) = await workspace(fixture)
    let index = try Data(contentsOf: fixture.root.appendingPathComponent(".git/index"))
    let draft = workspace.pullRequestDraft
    draft.body = ""
    let created = await draft.create(draft: false, generate: { content, _, _ in
      XCTAssertTrue(content.diff.contains("selected local change"))
      XCTAssertTrue(content.localDiff?.contains("selected local change") == true)
      try Data("changed while generating\n".utf8).write(to: fixture.root.appendingPathComponent("file.txt"))
      return GitPullRequestText(title: "Generated", body: "Stale description")
    }, prepareLocalChanges: true, commitMessage: "Local message")
    XCTAssertNil(created)
    XCTAssertTrue(draft.needsRefresh)
    XCTAssertEqual(draft.title, "Manual title")
    XCTAssertEqual(draft.body, "")
    XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(".git/index")), index)
    let head = try await git(["rev-parse", "HEAD"], at: fixture.root)
    XCTAssertEqual(head, fixture.head)
    XCTAssertEqual(try creates(fixture).count, 0)
  }

  @MainActor func testGenerationCancelledBeforeMutationKeepsIndexAndManualText() async throws {
    let fixture = try await fixture()
    try write("local change\n", in: fixture)
    let (_, workspace) = await workspace(fixture)
    let draft = workspace.pullRequestDraft
    draft.body = ""
    let index = try Data(contentsOf: fixture.root.appendingPathComponent(".git/index"))
    let created = await draft.create(draft: false, generate: { _, _, _ in
      await draft.cancelGeneration()
      return GitPullRequestText(title: "Cancelled", body: "Cancelled", commitMessage: "Cancelled")
    }, prepareLocalChanges: true)
    XCTAssertNil(created)
    XCTAssertFalse(draft.creating)
    XCTAssertFalse(draft.generating)
    XCTAssertEqual(draft.title, "Manual title")
    XCTAssertEqual(draft.body, "")
    XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(".git/index")), index)
    XCTAssertEqual(try creates(fixture).count, 0)
  }

  @MainActor func testReadOnlyAfterGenerationStopsBeforeFirstMutation() async throws {
    let fixture = try await fixture()
    try write("local change\n", in: fixture)
    let (store, workspace) = await workspace(fixture)
    let draft = workspace.pullRequestDraft
    let created = await draft.create(draft: false, generate: { _, _, _ in
      await MainActor.run { store.library.gitPreferences.readOnlyReview = true }
      return GitPullRequestText(title: "Generated", body: "Generated", commitMessage: "Generated local message")
    }, prepareLocalChanges: true, authorize: workspace.gitMutationAuthorization(at: fixture.root))
    XCTAssertNil(created)
    XCTAssertTrue(draft.error?.contains("只读") == true)
    let head = try await git(["rev-parse", "HEAD"], at: fixture.root)
    let staged = try await git(["diff", "--cached"], at: fixture.root)
    XCTAssertEqual(head, fixture.head)
    XCTAssertEqual(staged, "")
    XCTAssertEqual(draft.title, "Manual title")
    XCTAssertEqual(try creates(fixture).count, 0)
  }

  @MainActor func testReadOnlyAfterCommitPreventsPushWithoutUndoingCompletedCommit() async throws {
    let fixture = try await fixture()
    try write("local change\n", in: fixture)
    let (store, workspace) = await workspace(fixture)
    let draft = workspace.pullRequestDraft
    let created = await draft.create(draft: false, prepareLocalChanges: true,
      commitMessage: "Local message", onCommitted: { store.library.gitPreferences.readOnlyReview = true },
      authorize: workspace.gitMutationAuthorization(at: fixture.root))
    XCTAssertNil(created)
    let count = try await git(["rev-list", "--count", "HEAD"], at: fixture.root)
    let remote = try await git(["rev-parse", "refs/heads/feature/topic"], at: fixture.remote)
    XCTAssertEqual(count, "3")
    XCTAssertEqual(remote, fixture.head)
    XCTAssertEqual(try creates(fixture).count, 0)
  }

  @MainActor func testInvalidBaseCannotCommitOrPushEvenWithManualPRFields() async throws {
    let fixture = try await fixture()
    try write("local change\n", in: fixture)
    let (store, workspace) = await workspace(fixture)
    workspace.pullRequestDraft.base = "../invalid"
    await store.createPullRequest(in: workspace, draft: false)
    XCTAssertNotNil(workspace.pullRequestDraft.error)
    let head = try await git(["rev-parse", "HEAD"], at: fixture.root)
    XCTAssertEqual(head, fixture.head)
    XCTAssertEqual(try creates(fixture).count, 0)
  }

  @MainActor func testUncheckedGenerationSummarizesOnlyPublishedCommits() async throws {
    let fixture = try await fixture()
    try write("unpublished-secret-marker\n", in: fixture)
    _ = try await git(["commit", "-qam", "Unpublished"], at: fixture.root)
    try write("working-secret-marker\n", in: fixture)
    let (_, workspace) = await workspace(fixture)
    let draft = workspace.pullRequestDraft
    draft.includeLocalChanges = false
    draft.body = ""
    let created = await draft.create(draft: false, generate: { content, _, _ in
      XCTAssertTrue(content.diff.contains("published feature"))
      XCTAssertFalse(content.diff.contains("unpublished-secret-marker"))
      XCTAssertFalse(content.diff.contains("working-secret-marker"))
      XCTAssertFalse(content.commits.contains("Unpublished"))
      XCTAssertNil(content.localDiff)
      return GitPullRequestText(title: "Generated", body: "Published description")
    }, prepareLocalChanges: false)
    XCTAssertNotNil(created)
    XCTAssertEqual(draft.title, "Manual title")
    XCTAssertEqual(draft.body, "Published description")
    let remote = try await git(["rev-parse", "refs/heads/feature/topic"], at: fixture.remote)
    XCTAssertEqual(remote, fixture.head)
  }

  @MainActor func testMissingCommitMessageInGeneratedResultNeverStagesLocalChanges() async throws {
    let fixture = try await fixture()
    try write("local change\n", in: fixture)
    let (_, workspace) = await workspace(fixture)
    let draft = workspace.pullRequestDraft
    let created = await draft.create(draft: false, generate: { _, _, _ in
      GitPullRequestText(title: "Generated", body: "Generated")
    }, prepareLocalChanges: true)
    XCTAssertNil(created)
    XCTAssertTrue(draft.error?.contains("提交说明") == true)
    let staged = try await git(["diff", "--cached"], at: fixture.root)
    XCTAssertEqual(staged, "")
    XCTAssertEqual(try creates(fixture).count, 0)
  }

  @MainActor func testCommitHookChangingActualTreeStopsBeforePushAndKeepsCompletedCommit() async throws {
    let fixture = try await fixture()
    try write("reviewed change\n", in: fixture)
    _ = try hook("pre-commit", at: fixture.root.appendingPathComponent(".git"),
      contents: "#!/bin/sh\nprintf 'hook changed content\\n' > file.txt\n/usr/bin/git add -- file.txt\n")
    let (store, workspace) = await workspace(fixture)
    await store.createPullRequest(in: workspace, draft: false)
    XCTAssertTrue(workspace.pullRequestDraft.needsRefresh)
    XCTAssertTrue(workspace.pullRequestDraft.error?.contains("提交已成功") == true)
    let actual = try await git(["show", "HEAD:file.txt"], at: fixture.root)
    let remote = try await git(["rev-parse", "refs/heads/feature/topic"], at: fixture.remote)
    XCTAssertEqual(actual, "hook changed content")
    XCTAssertEqual(remote, fixture.head)
    XCTAssertEqual(workspace.commitMessage, "")
    XCTAssertEqual(try creates(fixture).count, 0)
  }

  @MainActor func testBaseAdvancingDuringGenerationDoesNotCommitOrPublishStaleDescription() async throws {
    let fixture = try await fixture()
    try write("local change\n", in: fixture)
    let (_, workspace) = await workspace(fixture)
    let draft = workspace.pullRequestDraft
    draft.body = ""
    let tree = try await git(["rev-parse", fixture.base + "^{tree}"], at: fixture.root)
    let advanced = try await git(["commit-tree", tree, "-p", fixture.base, "-m", "Advanced base"], at: fixture.root)
    _ = try await git(["push", fixture.remote.path, advanced + ":refs/heads/later-base"], at: fixture.root)
    let created = await draft.create(draft: false, generate: { _, _, _ in
      _ = try await GitReviewService.checked(["update-ref", "refs/heads/main", advanced], at: fixture.remote)
      return GitPullRequestText(title: "Generated", body: "Stale body")
    }, prepareLocalChanges: true, commitMessage: "Local message")
    XCTAssertNil(created)
    XCTAssertTrue(draft.needsRefresh)
    let head = try await git(["rev-parse", "HEAD"], at: fixture.root)
    XCTAssertEqual(head, fixture.head)
    XCTAssertEqual(draft.body, "")
    XCTAssertEqual(try creates(fixture).count, 0)
  }

  @MainActor func testEditingPRInputAfterCommitPreventsRemainingPublication() async throws {
    let fixture = try await fixture()
    try write("local change\n", in: fixture)
    let (_, workspace) = await workspace(fixture)
    let draft = workspace.pullRequestDraft
    let created = await draft.create(draft: false, prepareLocalChanges: true, commitMessage: "Local message",
      onCommitted: { draft.title = "Edited after commit" })
    XCTAssertNil(created)
    XCTAssertTrue(draft.error?.contains("手动修改") == true)
    XCTAssertEqual(draft.title, "Edited after commit")
    let count = try await git(["rev-list", "--count", "HEAD"], at: fixture.root)
    let remote = try await git(["rev-parse", "refs/heads/feature/topic"], at: fixture.remote)
    XCTAssertEqual(count, "3")
    XCTAssertEqual(remote, fixture.head)
    XCTAssertEqual(try creates(fixture).count, 0)
  }

  @MainActor func testIndependentAPICombinesGenerationBeforeCommitPushAndPRCreation() async throws {
    let fixture = try await fixture()
    try write("new local API marker\n", in: fixture)
    let (store, workspace) = await workspace(fixture)
    let log = fixture.root.appendingPathComponent(".git/pr-api-request.json")
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/model_server.py")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-u", script.path]
    process.environment = ["PR_REQUEST_LOG": log.path]
    let pipe = Pipe()
    process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    try process.run()
    defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
    let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertNotNil(Int(port))
    store.modelConfiguration.baseURL = "http://127.0.0.1:\(port)/v1"
    store.modelConfiguration.model = "fixture"
    store.library.gitPreferences.commitInstructions = "Commit guidance marker"
    store.library.gitPreferences.pullRequestInstructions = "PR guidance marker"
    workspace.commitMessage = ""
    workspace.pullRequestDraft.body = ""
    await store.createPullRequest(in: workspace, draft: true, taskID: "owner")
    XCTAssertNil(workspace.pullRequestDraft.error)
    XCTAssertEqual(workspace.pullRequestDraft.existing?.title, "Manual title")
    XCTAssertEqual(workspace.pullRequestDraft.body, "## Summary\n\nGenerated PR description.")
    let message = try await git(["log", "-1", "--format=%s"], at: fixture.root)
    let head = try await git(["rev-parse", "HEAD"], at: fixture.root)
    let remote = try await git(["rev-parse", "refs/heads/feature/topic"], at: fixture.remote)
    XCTAssertEqual(message, "Generated local commit")
    XCTAssertEqual(head, remote)
    XCTAssertEqual(try creates(fixture).count, 1)
    let request = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: log))
    let system = request["messages"].items.first?["content"].text ?? ""
    let input = request["messages"].items.last?["content"].text ?? ""
    XCTAssertTrue(system.contains("Commit guidance marker"))
    XCTAssertTrue(system.contains("PR guidance marker"))
    XCTAssertTrue(system.contains("\"commitMessage\""))
    XCTAssertTrue(input.contains("new local API marker"))
    XCTAssertTrue(input.contains("<local_changes_to_commit>"))
    XCTAssertTrue(input.contains("Published feature"))
    XCTAssertFalse(workspace.gitBusy)
    XCTAssertFalse(workspace.gitActionRunning)
  }
}
