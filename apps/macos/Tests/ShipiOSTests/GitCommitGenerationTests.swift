import XCTest
@testable import ShipiOS

final class GitCommitGenerationTests: XCTestCase {
  private var fixture: Process!
  private var root: URL!
  private var requestLog: URL!
  private var config = ModelConfiguration()

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    requestLog = root.appendingPathComponent("request.json")
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/model_server.py")
    fixture = Process()
    fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    fixture.arguments = ["-u", script.path]
    fixture.environment = ["COMMIT_REQUEST_LOG": requestLog.path]
    let pipe = Pipe()
    fixture.standardOutput = pipe; fixture.standardError = FileHandle.nullDevice
    try fixture.run()
    let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard Int(port) != nil else { throw AgentFailure(message: "Fixture failed") }
    config.baseURL = "http://127.0.0.1:\(port)/v1"; config.model = "fixture"
  }
  override func tearDown() {
    if fixture?.isRunning == true { fixture.terminate(); fixture.waitUntilExit() }
    try? FileManager.default.removeItem(at: root)
  }

  @MainActor private func workspace() async throws -> DeveloperWorkspace {
    _ = try await GitReviewService.checked(["init", "-q", "-b", "main"], at: root)
    try "staged-only\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    _ = try await GitReviewService.checked(["add", "file.txt"], at: root)
    let workspace = DeveloperWorkspace()
    workspace.root = root
    await workspace.refreshGit()
    XCTAssertTrue(workspace.canCommit)
    return workspace
  }
  private func waitForRequest() async throws {
    for _ in 0..<1000 {
      if FileManager.default.fileExists(atPath: requestLog.path) { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw AgentFailure(message: "No fixture request")
  }

  @MainActor func testStagedDiffAndSavedInstructionsReachModelWithoutCommittingOrIncludingWorktree() async throws {
    let workspace = try await workspace()
    try "unstaged-secret-placeholder\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    let indexBefore = try await GitReviewService.checked(["diff", "--cached"], at: root)
    workspace.generateCommitMessage(config: config, key: nil, instructions: "Use Chinese, keep the subject concise.")
    await workspace.commitGenerationTask?.value
    XCTAssertNil(workspace.commitGenerationError)
    let messages = try JSONDecoder().decode(JSONValue.self, from: Data(workspace.commitMessage.utf8))
    XCTAssertTrue(messages.items.first?["content"].text?.contains("Use Chinese") == true)
    XCTAssertTrue(messages.items.last?["content"].text?.contains("staged-only") == true)
    XCTAssertFalse(workspace.commitMessage.contains("unstaged-secret-placeholder"))
    let indexAfter = try await GitReviewService.checked(["diff", "--cached"], at: root)
    XCTAssertEqual(indexBefore, indexAfter)
    let head = try await LocalWorkspaceService.git(["rev-parse", "--verify", "HEAD"], at: root)
    XCTAssertNotEqual(head.status, 0, "Generating must not create a commit")
  }

  @MainActor func testManualDraftEditAndChangedIndexRejectStaleResults() async throws {
    let workspace = try await workspace()
    workspace.commitMessage = "original"
    workspace.generateCommitMessage(config: config, key: nil, instructions: "fixture-slow-commit")
    let first = try XCTUnwrap(workspace.commitGenerationTask)
    try await waitForRequest()
    workspace.commitMessage = "user edit"
    await first.value
    XCTAssertEqual(workspace.commitMessage, "user edit")
    XCTAssertTrue(workspace.commitGenerationError?.contains("手动修改") == true)
    try FileManager.default.removeItem(at: requestLog)
    workspace.generateCommitMessage(config: config, key: nil, instructions: "fixture-slow-commit")
    let second = try XCTUnwrap(workspace.commitGenerationTask)
    try await waitForRequest()
    try "changed staged content\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    _ = try await GitReviewService.checked(["add", "file.txt"], at: root)
    await second.value
    XCTAssertEqual(workspace.commitMessage, "user edit")
    XCTAssertTrue(workspace.commitGenerationError?.contains("暂存内容") == true)
  }

  @MainActor func testCancellationKeepsDraftAndReleasesGenerationState() async throws {
    let workspace = try await workspace()
    workspace.commitMessage = "keep me"
    workspace.generateCommitMessage(config: config, key: nil, instructions: "fixture-slow-commit")
    let task = try XCTUnwrap(workspace.commitGenerationTask)
    try await waitForRequest()
    workspace.cancelCommitMessageGeneration()
    await task.value
    XCTAssertEqual(workspace.commitMessage, "keep me")
    XCTAssertFalse(workspace.generatingCommitMessage)
    XCTAssertNil(workspace.commitGenerationTask)
    XCTAssertNil(workspace.commitGenerationError)
  }

  @MainActor func testEmptyIndexAndSubdirectoryCannotSendModelRequest() async throws {
    let workspace = try await workspace()
    _ = try await GitReviewService.checked(["rm", "--cached", "file.txt"], at: root)
    workspace.generateCommitMessage(config: config, key: nil, instructions: "")
    await workspace.commitGenerationTask?.value
    XCTAssertFalse(FileManager.default.fileExists(atPath: requestLog.path))
    XCTAssertNotNil(workspace.commitGenerationError)
    let subdirectory = root.appendingPathComponent("sub")
    try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
    do { _ = try await GitCommitContext.capture(at: subdirectory); XCTFail("Subdirectory must be rejected") }
    catch { XCTAssertTrue(error.localizedDescription.contains("根目录")) }
  }

  @MainActor func testCommitGuidanceMigratesPersistsAndRollsBackOnSaveFailure() throws {
    let legacy = try JSONDecoder().decode(GitPreferences.self, from: Data("{}".utf8))
    XCTAssertEqual(legacy.commitInstructions, "")
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Settings"))
    store.libraryLoaded = true
    var preferences = legacy
    preferences.commitInstructions = "Use concise Chinese subjects."
    XCTAssertTrue(store.saveGitPreferences(preferences))
    XCTAssertEqual(try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json")).gitPreferences.commitInstructions,
      preferences.commitInstructions)
    let file = store.dataRoot.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    try Data("preserve".utf8).write(to: file.appendingPathComponent("block"))
    var changed = preferences; changed.commitInstructions = "failed change"
    XCTAssertFalse(store.saveGitPreferences(changed))
    XCTAssertEqual(store.library.gitPreferences, preferences)
    XCTAssertEqual(SettingsSearch.results(for: "提交指令").compactMap(\.field), [.commitInstructions])
  }

  @MainActor func testIncludeUnstagedGenerationSendsSelectedContentWithoutStagingIt() async throws {
    let workspace = try await workspace()
    try "request.json\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    try "working-version\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    try "new-file-content\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
    let before = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    workspace.generateCommitMessage(config: config, key: nil, instructions: "Keep it concise", includeUnstaged: true)
    await workspace.commitGenerationTask?.value
    XCTAssertNil(workspace.commitGenerationError)
    XCTAssertTrue(workspace.commitMessage.contains("working-version"))
    XCTAssertTrue(workspace.commitMessage.contains("new-file-content"))
    XCTAssertFalse(workspace.commitMessage.contains("staged-only"))
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), before)
  }

  @MainActor func testCancelledAutomaticGenerationDoesNotStageOrCreateRequestedBranch() async throws {
    let workspace = try await workspace()
    try "request.json\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    try "working-version\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent(".git/shipios-test"))
    store.modelConfiguration = config
    store.library.gitPreferences.commitInstructions = "fixture-slow-commit"
    let indexBefore = try await GitReviewService.checked(["diff", "--cached"], at: root)
    let task = Task { await store.performGitAction(.commit, in: workspace,
      includeUnstaged: true, newBranch: "codex/cancelled") }
    try await waitForRequest()
    workspace.cancelCommitMessageGeneration()
    let result = await task.value
    XCTAssertFalse(result)
    XCTAssertFalse(workspace.gitActionRunning)
    XCTAssertEqual(workspace.commitMessage, "")
    let branch = try await GitReviewService.checked(["branch", "--show-current"], at: root)
    XCTAssertEqual(branch.trimmingCharacters(in: .newlines), "main")
    let indexAfter = try await GitReviewService.checked(["diff", "--cached"], at: root)
    XCTAssertEqual(indexBefore, indexAfter)
    let head = try await LocalWorkspaceService.git(["rev-parse", "--verify", "HEAD"], at: root)
    XCTAssertNotEqual(head.status, 0)
  }
}
