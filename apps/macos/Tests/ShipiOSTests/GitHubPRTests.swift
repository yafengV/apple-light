import XCTest
@testable import ShipiOS

final class GitHubPRTests: XCTestCase {
  private func git(_ args: [String], at root: URL) async throws -> String {
    try await GitReviewService.checked(args, at: root).trimmingCharacters(in: .newlines)
  }
  private func fixture() async throws -> (URL, GitHubPRService) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    _ = try await git(["init", "-q", "-b", "main"], at: root)
    _ = try await git(["config", "user.name", "Test"], at: root)
    _ = try await git(["config", "user.email", "test@example.invalid"], at: root)
    try Data("initial".utf8).write(to: root.appendingPathComponent("file.txt"))
    _ = try await git(["add", "--all"], at: root)
    _ = try await git(["commit", "-qm", "initial"], at: root)
    let base = try await git(["rev-parse", "HEAD"], at: root)
    _ = try await git(["switch", "-c", "feature/topic"], at: root)
    try Data("changed".utf8).write(to: root.appendingPathComponent("file.txt"))
    _ = try await git(["commit", "-am", "feature"], at: root)
    let head = try await git(["rev-parse", "HEAD"], at: root)
    _ = try await git(["remote", "add", "origin", "git@github.com:sample/project.git"], at: root)
    _ = try await git(["update-ref", "refs/remotes/origin/main", base], at: root)
    _ = try await git(["update-ref", "refs/remotes/origin/feature/topic", head], at: root)
    _ = try await git(["branch", "--set-upstream-to=origin/feature/topic"], at: root)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/github_cli.py")
    let executable = root.appendingPathComponent(".git/gh-fixture")
    try FileManager.default.copyItem(at: source, to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    try save(["head": head, "base": base], at: root)
    return (root, GitHubPRService(executable: executable))
  }
  private func state(at root: URL) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(".git/github-fixture.json"))) as? [String: Any])
  }
  private func save(_ state: [String: Any], at root: URL) throws {
    try JSONSerialization.data(withJSONObject: state).write(to: root.appendingPathComponent(".git/github-fixture.json"))
  }
  private func requests(at root: URL) throws -> [[String: Any]] {
    let file = root.appendingPathComponent(".git/github-requests.jsonl")
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
      try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
  }
  private func creates(at root: URL) throws -> [[String: Any]] {
    try requests(at: root).filter { ($0["args"] as? [String])?.prefix(2) == ["pr", "create"] }
  }

  func testRepositoryAndPullRequestLinksAreValidated() throws {
    let repo = try GitHubRepository.parse("git@github.com:sample/project.git")
    XCTAssertEqual(try GitHubRepository.parse("https://github.com/sample/project"), repo)
    XCTAssertEqual(try GitHubRepository.parse("ssh://git@github.com/sample/project.git"), repo)
    XCTAssertNotNil(repo.pullRequestURL("https://github.com/sample/project/pull/42"))
    for invalid in ["https://github.com/other/project/pull/42", "javascript:alert(1)", "https://github.com/sample/project/pull/42?next=bad"] {
      XCTAssertNil(repo.pullRequestURL(invalid))
    }
    XCTAssertThrowsError(try GitHubRepository.parse("https://token@github.com/sample/project"))
    XCTAssertThrowsError(try GitHubRepository.parse("https://gitlab.com/sample/project"))
  }

  @MainActor func testCreatedPRPersistsOnlyForOwningTaskAndIsRemovedWithTask() async throws {
    let (root, service) = try await fixture()
    let dataRoot = root.appendingPathComponent(".git/shipios-state")
    let store = WorkspaceStore(dataRoot: dataRoot)
    store.libraryLoaded = true
    store.library.tasks = [
      WorkspaceTask(id: "owner", project: root.path, title: "Owner", runIDs: []),
      WorkspaceTask(id: "other", project: root.path, title: "Other", runIDs: []),
    ]
    let workspace = DeveloperWorkspace()
    workspace.root = root
    workspace.pullRequestDraft = GitHubPRDraft(service: service)
    await workspace.pullRequestDraft.load(at: root)
    workspace.pullRequestDraft.title = "Feature title"
    workspace.pullRequestDraft.body = "Feature body"

    await store.createPullRequest(in: workspace, draft: true, taskID: "owner")
    let created = try XCTUnwrap(workspace.pullRequestDraft.existing)
    XCTAssertEqual(store.library.taskPullRequests["owner"], [created])
    XCTAssertNil(store.library.taskPullRequests["other"])
    XCTAssertNotNil(created.validatedURL)

    let repository = try GitHubRepository.parse("git@github.com:sample/project.git")
    XCTAssertTrue(store.recordPullRequest(created, for: "owner", at: root, repository: repository))
    XCTAssertEqual(store.library.taskPullRequests["owner"]?.count, 1)
    XCTAssertFalse(store.recordPullRequest(created, for: "missing", at: root, repository: repository))
    XCTAssertFalse(store.recordPullRequest(created, for: "other",
      at: root.appendingPathComponent("wrong"), repository: repository))

    var reloaded = try WorkspaceLibrary.load(from: dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(reloaded.taskPullRequests["owner"], [created])
    XCTAssertNil(reloaded.taskPullRequests["other"])
    reloaded.tasks[0].archived = true
    _ = reloaded.deleteArchivedTasks(["owner"])
    XCTAssertNil(reloaded.taskPullRequests["owner"])
  }

  func testSummaryRejectsUnsafeStoredPRLinks() {
    let request = GitHubPullRequest(number: 42, url: "https://github.com/sample/project/pull/42",
      title: "Feature", isDraft: false, headRefName: "feature", baseRefName: "main",
      isCrossRepository: false)
    XCTAssertNotNil(request.validatedURL)
    for invalid in ["https://github.com/sample/project/pull/42?next=bad",
      "https://github.com/sample/project/pull/43", "https://evil.example/pull/42"] {
      let unsafe = GitHubPullRequest(number: request.number, url: invalid,
        title: request.title, isDraft: request.isDraft, headRefName: request.headRefName,
        baseRefName: request.baseRefName, isCrossRepository: request.isCrossRepository)
      XCTAssertNil(unsafe.validatedURL)
    }
  }

  func testDraftCreationUsesExplicitHeadAndPrivateBodyFileAndPreventsDuplicates() async throws {
    let (root, service) = try await fixture()
    var config = try state(at: root); config["inactiveFailure"] = true; try save(config, at: root)
    let context = try await service.inspect(at: root)
    XCTAssertNil(context.creationProblem)
    let body = "First line\n\n`$(do-not-execute)` and 中文"
    let result = try await service.create(context, base: "main", title: "Feature title", body: body, draft: true)
    XCTAssertEqual(result.number, 42)
    XCTAssertTrue(result.isDraft)
    let writes = try creates(at: root)
    XCTAssertEqual(writes.count, 1)
    let call = try XCTUnwrap(writes.first)
    XCTAssertEqual(call["body"] as? String, body)
    XCTAssertEqual(call["bodyMode"] as? String, "0o600")
    let args = try XCTUnwrap(call["args"] as? [String])
    XCTAssertTrue(args.contains("--draft"))
    XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--head")) + 1], "feature/topic")
    let file = args[try XCTUnwrap(args.firstIndex(of: "--body-file")) + 1]
    XCTAssertFalse(FileManager.default.fileExists(atPath: file))
    let existing = try await service.create(context, base: "main", title: "ignored", body: "", draft: false)
    XCTAssertEqual(existing.number, 42)
    XCTAssertEqual(try creates(at: root).count, 1)
  }

  func testChangedHeadAndUnpublishedCommitsNeverCreatePR() async throws {
    let (root, service) = try await fixture()
    let previous = try await service.inspect(at: root)
    _ = try await git(["commit", "--allow-empty", "-m", "later"], at: root)
    do { _ = try await service.create(previous, base: "main", title: "stale", body: "", draft: false); XCTFail("must reject changed head") }
    catch { XCTAssertTrue(error.localizedDescription.contains("已改变")) }
    let current = try await service.inspect(at: root)
    XCTAssertTrue(current.creationProblem?.contains("先推送") == true)
    XCTAssertEqual(try creates(at: root).count, 0)
  }

  @MainActor func testUncertainCreateRetainsInputAndRefreshRecoversExistingPR() async throws {
    let (root, service) = try await fixture()
    var config = try state(at: root); config["failAfterCreate"] = true; try save(config, at: root)
    let draft = GitHubPRDraft(service: service)
    await draft.load(at: root)
    draft.title = "Keep title"; draft.body = "Keep body"
    let result = await draft.create(draft: false)
    XCTAssertNil(result)
    XCTAssertTrue(draft.needsRefresh)
    XCTAssertFalse(draft.canCreate)
    XCTAssertEqual(draft.title, "Keep title")
    XCTAssertEqual(draft.body, "Keep body")
    XCTAssertEqual(try creates(at: root).count, 1)
    await draft.load(at: root)
    XCTAssertEqual(draft.existing?.number, 42)
    XCTAssertFalse(draft.needsRefresh)
    XCTAssertEqual(draft.title, "Keep title")
    XCTAssertEqual(try creates(at: root).count, 1)
  }

  func testMissingCLIAuthenticationAndRemoteMismatchAreReported() async throws {
    let (root, service) = try await fixture()
    let missing = GitHubPRService(executable: root.appendingPathComponent(".git/missing-gh"))
    do { _ = try await missing.inspect(at: root); XCTFail("missing CLI") }
    catch { XCTAssertTrue(error.localizedDescription.contains("尚未安装")) }
    try FileManager.default.copyItem(at: XCTUnwrap(service.executable), to: XCTUnwrap(missing.executable))
    let installed = try await missing.inspect(at: root)
    XCTAssertNil(installed.creationProblem, "Installing the CLI must allow retry with the same service")
    var config = try state(at: root); config["authFailure"] = true; try save(config, at: root)
    do { _ = try await service.inspect(at: root); XCTFail("missing auth") }
    catch { XCTAssertTrue(error.localizedDescription.contains("gh auth login")) }
    config["authFailure"] = false; config["published"] = String(repeating: "a", count: 40); try save(config, at: root)
    let mismatched = try await service.inspect(at: root)
    XCTAssertTrue(mismatched.creationProblem?.contains("不一致") == true)
    XCTAssertEqual(try creates(at: root).count, 0)
  }

  @MainActor func testReadOnlyReviewAndDraftPreference() async throws {
    let (root, service) = try await fixture()
    let workspace = DeveloperWorkspace(); workspace.root = root
    workspace.pullRequestDraft = GitHubPRDraft(service: service)
    await workspace.pullRequestDraft.load(at: root)
    workspace.pullRequestDraft.title = "Title"
    workspace.pullRequestDraft.body = "Manual description"
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent(".git/settings"))
    store.libraryLoaded = true
    var prefs = GitPreferences(); prefs.createDraftPullRequests = true; prefs.readOnlyReview = true
    XCTAssertTrue(store.saveGitPreferences(prefs))
    await store.createPullRequest(in: workspace, draft: true)
    XCTAssertEqual(try creates(at: root).count, 0)
    prefs.readOnlyReview = false; XCTAssertTrue(store.saveGitPreferences(prefs))
    await store.createPullRequest(in: workspace, draft: store.library.gitPreferences.createDraftPullRequests)
    XCTAssertEqual(workspace.pullRequestDraft.existing?.isDraft, true)
    XCTAssertFalse(workspace.gitBusy)
    XCTAssertTrue(try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json")).gitPreferences.createDraftPullRequests)
    XCTAssertFalse(try JSONDecoder().decode(GitPreferences.self, from: Data("{}".utf8)).createDraftPullRequests)
    XCTAssertTrue(SettingsSearch.results(for: "draft pull request").contains { $0.field == .createDraftPullRequests })
  }

  @MainActor func testValidationFailureCanBeEditedWithoutPublishingOrLosingDraft() async throws {
    let (root, service) = try await fixture()
    let draft = GitHubPRDraft(service: service)
    await draft.load(at: root)
    draft.title = "Invalid\nTitle"; draft.body = "Keep description"
    let rejected = await draft.create(draft: false)
    XCTAssertNil(rejected)
    XCTAssertFalse(draft.needsRefresh)
    XCTAssertEqual(draft.body, "Keep description")
    XCTAssertEqual(try creates(at: root).count, 0)
    draft.title = "Valid title"
    XCTAssertTrue(draft.canCreate)
    let created = await draft.create(draft: false)
    XCTAssertEqual(created?.isDraft, false)
    XCTAssertEqual(try creates(at: root).count, 1)
  }

  func testGenerationUsesPublishedCommitsAndExcludesIndexAndWorkingTree() async throws {
    let (root, service) = try await fixture()
    let context = try await service.inspect(at: root)
    try Data("staged-private-placeholder".utf8).write(to: root.appendingPathComponent("file.txt"))
    _ = try await git(["add", "file.txt"], at: root)
    try Data("unstaged-private-placeholder".utf8).write(to: root.appendingPathComponent("file.txt"))
    let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    let content = try await service.generationContent(context, base: "main")
    XCTAssertTrue(content.diff.contains("changed"))
    XCTAssertTrue(content.commits.contains("feature"))
    XCTAssertFalse(content.diff.contains("private-placeholder"))
    let messages = content.messages(instructions: "Use Chinese", title: "Manual title", body: "")
    XCTAssertTrue(messages[0].content.contains("Use Chinese"))
    XCTAssertTrue(messages[1].content.contains("Manual title"))
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), index)
    XCTAssertEqual(try creates(at: root).count, 0)
    let result = try GitPullRequestText.parse("{\"title\":\"A title\",\"body\":\"A description\"}")
    XCTAssertEqual(result.title, "A title")
    for invalid in ["", "{}", "```json\n{}\n```", "{\"title\":\"bad\\ntitle\",\"body\":\"body\"}", "{\"title\":\"title\",\"body\":\" \"}"] {
      XCTAssertThrowsError(try GitPullRequestText.parse(invalid))
    }
  }

  @MainActor func testAutomaticGenerationCreatesDraftAndPreservesManuallyEnteredTitle() async throws {
    let (root, service) = try await fixture()
    let draft = GitHubPRDraft(service: service)
    await draft.load(at: root)
    draft.title = "Manually entered title"
    XCTAssertTrue(draft.canCreate)
    let result = await draft.create(draft: true, generate: { content, title, body in
      XCTAssertEqual(title, "Manually entered title")
      XCTAssertEqual(body, "")
      XCTAssertTrue(content.diff.contains("changed"))
      return GitPullRequestText(title: "Generated title", body: "Generated description")
    })
    XCTAssertEqual(result?.title, "Manually entered title")
    XCTAssertEqual(draft.body, "Generated description")
    XCTAssertTrue(result?.isDraft == true)
    XCTAssertFalse(draft.generating)
    XCTAssertFalse(draft.creating)
    XCTAssertEqual(try creates(at: root).count, 1)
  }

  @MainActor func testCancelGenerationKeepsInputsAndNeverPublishes() async throws {
    let (root, service) = try await fixture()
    let draft = GitHubPRDraft(service: service)
    await draft.load(at: root)
    draft.title = "Keep title"
    let marker = root.appendingPathComponent(".git/generation-started")
    let operation = Task {
      await draft.create(draft: false, generate: { _, _, _ in
        try Data().write(to: marker)
        try await Task.sleep(for: .seconds(30))
        return GitPullRequestText(title: "Ignored", body: "Ignored")
      })
    }
    for _ in 0..<1500 {
      if FileManager.default.fileExists(atPath: marker.path) { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    draft.cancelGeneration()
    let result = await operation.value
    XCTAssertNil(result)
    XCTAssertNil(draft.error)
    XCTAssertEqual(draft.title, "Keep title")
    XCTAssertEqual(draft.body, "")
    XCTAssertFalse(draft.creating)
    XCTAssertFalse(draft.generating)
    XCTAssertTrue(draft.canCreate)
    XCTAssertEqual(try creates(at: root).count, 0)
  }

  @MainActor func testChangedBranchDuringGenerationRejectsGeneratedTextBeforePublishing() async throws {
    let (root, service) = try await fixture()
    let draft = GitHubPRDraft(service: service)
    await draft.load(at: root)
    draft.title = "Keep title"
    let result = await draft.create(draft: false, generate: { _, _, _ in
      _ = try await GitReviewService.checked(["commit", "--allow-empty", "-m", "new commit"], at: root)
      return GitPullRequestText(title: "Generated", body: "Generated")
    })
    XCTAssertNil(result)
    XCTAssertTrue(draft.needsRefresh)
    XCTAssertEqual(draft.title, "Keep title")
    XCTAssertEqual(draft.body, "")
    XCTAssertEqual(try creates(at: root).count, 0)
  }

  @MainActor func testFailedGenerationRetainsDescriptionAndCanRetryMissingTitle() async throws {
    let (root, service) = try await fixture()
    let draft = GitHubPRDraft(service: service)
    await draft.load(at: root)
    draft.body = "Manual description"
    let failed = await draft.create(draft: false, generate: { _, _, _ in try GitPullRequestText.parse("invalid") })
    XCTAssertNil(failed)
    XCTAssertEqual(draft.body, "Manual description")
    XCTAssertEqual(draft.title, "")
    XCTAssertTrue(draft.canCreate)
    XCTAssertFalse(draft.needsRefresh)
    XCTAssertEqual(try creates(at: root).count, 0)
    let result = await draft.create(draft: false, generate: { _, _, body in
      XCTAssertEqual(body, "Manual description")
      return GitPullRequestText(title: "Generated title", body: "Ignored")
    })
    XCTAssertEqual(result?.title, "Generated title")
    XCTAssertEqual(draft.body, "Manual description")
  }

  @MainActor func testPRGuidancePersistsMigratesAndRollsBack() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    var preferences = try JSONDecoder().decode(GitPreferences.self, from: Data("{}".utf8))
    XCTAssertEqual(preferences.pullRequestInstructions, "")
    preferences.pullRequestInstructions = "Use Chinese; include a testing section."
    XCTAssertTrue(store.saveGitPreferences(preferences))
    let file = root.appendingPathComponent("workspace.json")
    XCTAssertEqual(try WorkspaceLibrary.load(from: file).gitPreferences.pullRequestInstructions, preferences.pullRequestInstructions)
    XCTAssertEqual(SettingsSearch.results(for: "PR 指令").compactMap(\.field), [.pullRequestInstructions])
    var tooLong = preferences; tooLong.pullRequestInstructions = String(repeating: "字", count: 6000)
    XCTAssertFalse(store.saveGitPreferences(tooLong))
    XCTAssertEqual(store.library.gitPreferences, preferences)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    try Data("preserve".utf8).write(to: file.appendingPathComponent("block"))
    var changed = preferences; changed.pullRequestInstructions = "Failed change"
    XCTAssertFalse(store.saveGitPreferences(changed))
    XCTAssertEqual(store.library.gitPreferences, preferences)
  }

  @MainActor func testManualEditsDuringGenerationAreNeverOverwrittenOrPublished() async throws {
    let (root, service) = try await fixture()
    let draft = GitHubPRDraft(service: service)
    await draft.load(at: root)
    let result = await draft.create(draft: false, generate: { _, _, _ in
      await MainActor.run { draft.title = "Edited title"; draft.body = "Edited description" }
      return GitPullRequestText(title: "Old generated title", body: "Old generated description")
    })
    XCTAssertNil(result)
    XCTAssertEqual(draft.title, "Edited title")
    XCTAssertEqual(draft.body, "Edited description")
    XCTAssertTrue(draft.error?.contains("手动修改") == true)
    XCTAssertEqual(try creates(at: root).count, 0)
  }

  @MainActor func testRemoteBaseAdvanceDuringGenerationRequiresRefresh() async throws {
    let (root, service) = try await fixture()
    let draft = GitHubPRDraft(service: service)
    await draft.load(at: root)
    let base = try gitOIDState(root)
    let tree = try await git(["rev-parse", base + "^{tree}"], at: root)
    let advanced = try await git(["commit-tree", tree, "-p", base, "-m", "base advanced"], at: root)
    let result = await draft.create(draft: false, generate: { _, _, _ in
      let file = root.appendingPathComponent(".git/github-fixture.json")
      var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
      state["base"] = advanced
      try JSONSerialization.data(withJSONObject: state).write(to: file)
      return GitPullRequestText(title: "Stale title", body: "Stale description")
    })
    XCTAssertNil(result)
    XCTAssertTrue(draft.needsRefresh)
    XCTAssertEqual(draft.title, "")
    XCTAssertEqual(draft.body, "")
    XCTAssertEqual(try creates(at: root).count, 0)
  }

  private func gitOIDState(_ root: URL) throws -> String {
    try XCTUnwrap(state(at: root)["base"] as? String)
  }

  @MainActor func testIndependentAPIReceivesPRGuidanceAndCreatesFromGeneratedContent() async throws {
    let (root, service) = try await fixture()
    let requestLog = root.appendingPathComponent(".git/pr-request.json")
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/model_server.py")
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-u", script.path]; process.environment = ["PR_REQUEST_LOG": requestLog.path]
    let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
    try process.run()
    defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
    let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertNotNil(Int(port))
    let workspace = DeveloperWorkspace(); workspace.root = root
    workspace.pullRequestDraft = GitHubPRDraft(service: service)
    await workspace.pullRequestDraft.load(at: root)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent(".git/settings"))
    store.modelConfiguration.baseURL = "http://127.0.0.1:\(port)/v1"
    store.modelConfiguration.model = "fixture"
    store.library.gitPreferences.pullRequestInstructions = "Use Chinese; never invent tests."
    await store.createPullRequest(in: workspace, draft: false)
    XCTAssertNil(workspace.pullRequestDraft.error)
    XCTAssertEqual(workspace.pullRequestDraft.existing?.title, "Generated PR title")
    XCTAssertEqual(workspace.pullRequestDraft.body, "## Summary\n\nGenerated PR description.")
    let request = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: requestLog))
    XCTAssertTrue(request["messages"].items.first?["content"].text?.contains("Use Chinese; never invent tests.") == true)
    XCTAssertTrue(request["messages"].items.last?["content"].text?.contains("changed") == true)
    XCTAssertFalse(workspace.gitBusy)
    XCTAssertEqual(try creates(at: root).count, 1)
  }
}
