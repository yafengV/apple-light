import XCTest
@testable import ShipiOS

final class GitCommitSummaryTests: XCTestCase {
  private func git(_ arguments: [String], at root: URL) async throws {
    _ = try await GitReviewService.checked(arguments, at: root)
  }
  private func repository() async throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    try await git(["init", "-q", "-b", "main"], at: root)
    try await git(["config", "user.name", "Test"], at: root)
    try await git(["config", "user.email", "test@example.invalid"], at: root)
    return root
  }
  private func write(_ path: String, _ text: String, at root: URL) throws {
    try Data(text.utf8).write(to: root.appendingPathComponent(path))
  }

  func testBranchSuggestionMatchesTitleWordLimitAndPreservesPrefix() {
    XCTAssertEqual(GitBranchSuggestion.name(prefix: "codex/", title: " Fix: Task-Window UI & tests now "),
      "codex/fix-taskwindow-ui-tests")
    XCTAssertEqual(GitBranchSuggestion.name(prefix: " topic/ ", title: "A B C D E F"), "topic/a-b-c-d-e")
    XCTAssertEqual(GitBranchSuggestion.name(prefix: "", title: "Ticket #42: Add API_v2!"), "ticket-42-add-apiv2")
    XCTAssertEqual(GitBranchSuggestion.name(prefix: "codex/", title: "修复 设置 页面"), "codex/")
    XCTAssertEqual(GitBranchSuggestion.name(prefix: "custom-", title: nil), "custom-")
    XCTAssertEqual(GitBranchSuggestion.name(prefix: "", title: "\nOne\tTwo\rThree"), "one-two-three")
  }

  @MainActor func testIndependentTaskTitleNeverUsesMainWindowSelection() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.library.tasks = [
      WorkspaceTask(id: "main-task", project: "/one", title: "Main window task", runIDs: ["run-one"]),
      WorkspaceTask(id: "other-task", project: "/two", title: "Independent task", runIDs: ["run-two"]),
    ]
    store.selection = "run-one"
    XCTAssertEqual(store.gitCommitTaskTitle(taskID: nil), "Main window task")
    XCTAssertEqual(store.gitCommitTaskTitle(taskID: "other-task"), "Independent task")
    XCTAssertNil(store.gitCommitTaskTitle(taskID: "removed-task"))
  }

  func testNulStatsHandleRenamesBinaryAndUnusualPaths() throws {
    let text = "2\t1\tfile\twith\ntabs\0" + "0\t0\t\0old\nname\0new\tname\0" + "-\t-\timage.bin\0"
    XCTAssertEqual(try GitCommitSummary.parse(text),
      GitCommitSummary(files: 3, additions: 2, deletions: 1, binaryFiles: 1))
    XCTAssertFalse(try GitCommitSummary.parse("").hasChanges)
    for invalid in ["1\t2\tfile", "0\t0\t\0old\0", "-\t1\tfile\0", "-1\t0\tfile\0",
      "\(Int.max)\t0\tfirst\0" + "1\t0\tsecond\0"] {
      XCTAssertThrowsError(try GitCommitSummary.parse(invalid))
    }
  }

  func testRealStatsMatchSelectedContentAndLeaveIndexUntouched() async throws {
    let root = try await repository()
    try write("file.txt", "one\ntwo\nthree\n", at: root)
    try write("old.txt", "same\n", at: root)
    try write(".gitignore", "ignored.txt\n", at: root)
    try Data([0, 1]).write(to: root.appendingPathComponent("binary.bin"))
    try await git(["add", "--all"], at: root)
    try await git(["commit", "-qm", "initial"], at: root)
    try write("file.txt", "one\nTWO\nthree\nfour\n", at: root)
    try await git(["mv", "old.txt", "new\tline\nname.txt"], at: root)
    try Data([0, 2]).write(to: root.appendingPathComponent("binary.bin"))
    try await git(["add", "--all"], at: root)
    try write("file.txt", "one\ntwo\nthree\n", at: root)
    try write("new.txt", "hello\nworld\n", at: root)
    try write("ignored.txt", "ignored\n", at: root)
    let before = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    let staged = try await GitCommitSummary.capture(at: root, includeUnstaged: false)
    XCTAssertEqual(staged, GitCommitSummary(files: 3, additions: 2, deletions: 1, binaryFiles: 1))
    let all = try await GitCommitSummary.capture(at: root, includeUnstaged: true)
    XCTAssertEqual(all, GitCommitSummary(files: 3, additions: 2, deletions: 0, binaryFiles: 1))
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), before)
  }

  func testUnbornAndLargeDiffStatisticsDoNotRequireModelSizedPatch() async throws {
    let root = try await repository()
    let empty = try await GitCommitSummary.capture(at: root, includeUnstaged: false)
    XCTAssertFalse(empty.hasChanges)
    try write("large.txt", String(repeating: "line-content\n", count: 60_000), at: root)
    let full = try await GitCommitSummary.capture(at: root, includeUnstaged: true)
    XCTAssertEqual(full, GitCommitSummary(files: 1, additions: 60_000, deletions: 0, binaryFiles: 0))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/index").path))
    let staged = try await GitCommitSummary.capture(at: root, includeUnstaged: false)
    XCTAssertFalse(staged.hasChanges)
  }

  @MainActor func testOldScopeCompletionCannotReplaceNewSummaryOrErrorState() async throws {
    var pending: [Bool: CheckedContinuation<GitCommitSummary, Error>] = [:]
    let loader = GitCommitSummaryLoader { _, include in
      try await withCheckedThrowingContinuation { pending[include] = $0 }
    }
    let old = GitCommitSummaryRequest(root: URL(fileURLWithPath: "/tmp/old"), includeUnstaged: false, revision: UUID())
    let new = GitCommitSummaryRequest(root: URL(fileURLWithPath: "/tmp/new"), includeUnstaged: true, revision: UUID())
    let first = Task { await loader.load(old) }
    for _ in 0..<1000 where pending[false] == nil { await Task.yield() }
    let oldContinuation = try XCTUnwrap(pending[false])
    let second = Task { await loader.load(new) }
    for _ in 0..<1000 where pending[true] == nil { await Task.yield() }
    let newContinuation = try XCTUnwrap(pending[true])
    XCTAssertTrue(loader.loading)
    newContinuation.resume(returning: GitCommitSummary(files: 1, additions: 10))
    await second.value
    oldContinuation.resume(throwing: AgentFailure(message: "old failure"))
    await first.value
    XCTAssertEqual(loader.request, new)
    XCTAssertEqual(loader.summary?.additions, 10)
    XCTAssertNil(loader.error)
    XCTAssertFalse(loader.loading)
  }

  @MainActor func testCancellationAndRetryDoNotDisplayStaleCounts() async throws {
    var continuation: CheckedContinuation<GitCommitSummary, Error>?
    var attempts = 0
    let loader = GitCommitSummaryLoader { _, _ in
      attempts += 1
      if attempts == 1 { return try await withCheckedThrowingContinuation { continuation = $0 } }
      if attempts == 2 { throw AgentFailure(message: "read failed") }
      return GitCommitSummary(files: 1, additions: 3)
    }
    let request = GitCommitSummaryRequest(root: URL(fileURLWithPath: "/tmp/test"), includeUnstaged: true, revision: UUID())
    let task = Task { await loader.load(request) }
    for _ in 0..<1000 where continuation == nil { await Task.yield() }
    let waiting = try XCTUnwrap(continuation)
    task.cancel()
    waiting.resume(returning: GitCommitSummary(files: 1, additions: 99))
    await task.value
    XCTAssertNil(loader.summary)
    XCTAssertFalse(loader.loading)
    await loader.load(request)
    XCTAssertEqual(loader.error, "read failed")
    await loader.load(request)
    XCTAssertNil(loader.error)
    XCTAssertEqual(loader.summary?.additions, 3)
  }
}
