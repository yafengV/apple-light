import XCTest

@testable import ShipiOS

final class ReviewCommentsTests: XCTestCase {
  private func anchor(_ path: String = "file.swift", project: String = "/app") -> ReviewAnchor {
    .init(
      project: project, path: path, scope: "未暂存", revision: "working tree",
      fingerprint: "snapshot", oldLine: 7, newLine: 8, code: "let value = 1")
  }

  func testDiffLineNumbersAcrossHunksAndMissingNewline() {
    let patch = ReviewDiff(
      """
      diff --git a/file b/file
      --- a/file
      +++ b/file
      @@ -7,2 +7,3 @@ method
       context
      -removed
      +added
      +second
      \\ No newline at end of file
      @@ -20 +21 @@
      -old
      +new
      """)
    let code = patch.lines.filter(\.canComment)
    XCTAssertEqual(code.map(\.oldLine), [7, 8, nil, nil, 20, nil])
    XCTAssertEqual(code.map(\.newLine), [7, nil, 8, 9, nil, 21])
    XCTAssertEqual(patch.additions, 3)
    XCTAssertEqual(patch.deletions, 2)
    XCTAssertEqual(patch.lines.filter { $0.kind == .header }.count, 2)
    XCTAssertFalse(patch.lines.first!.canComment)
    XCTAssertEqual(
      patch.fingerprint,
      ReviewDiff(
        """
        diff --git a/file b/file
        --- a/file
        +++ b/file
        @@ -7,2 +7,3 @@ method
         context
        -removed
        +added
        +second
        \\ No newline at end of file
        @@ -20 +21 @@
        -old
        +new
        """
      ).fingerprint)
  }

  func testNewDeletedEmptyAndBinaryDiffs() {
    let created = ReviewDiff.untracked("hello\n\n")
    XCTAssertEqual(created.lines.filter(\.canComment).map(\.newLine), [1, 2])
    XCTAssertEqual(created.additions, 2)
    XCTAssertEqual(ReviewDiff.untracked("").additions, 0)
    let removed = ReviewDiff("@@ -1,2 +0,0 @@\n-first\n-second\n")
    XCTAssertEqual(removed.lines.filter(\.canComment).map(\.oldLine), [1, 2])
    XCTAssertTrue(removed.lines.allSatisfy { $0.newLine == nil })
    XCTAssertFalse(ReviewDiff("Binary files a/icon and b/icon differ").lines[0].canComment)
    XCTAssertFalse(
      ReviewDiff("@@ -9223372036854775807,2 +1,2 @@\n+bad").lines.contains(where: \.canComment))
    XCTAssertNotEqual(created.fingerprint, ReviewDiff.untracked("changed\n").fingerprint)
  }

  @MainActor func testCommentEditingCancelPersistenceAndTaskIsolation() throws {
    let store = WorkspaceStore()
    store.project = URL(fileURLWithPath: "/app")
    store.beginReviewComment(anchor())
    let id = try XCTUnwrap(store.reviewComments.first?.id)
    store.updateReviewComment(id, text: "  check bounds  ")
    store.saveReviewComment(id)
    XCTAssertEqual(store.reviewComments.first?.body, "check bounds")
    store.editReviewComment(id)
    store.updateReviewComment(id, text: "unsaved revision")
    let restored = try JSONDecoder().decode(
      WorkspaceLibrary.self, from: JSONEncoder().encode(store.library))
    XCTAssertEqual(restored.reviewComments["new:/app"]?.first?.editingText, "unsaved revision")
    store.cancelReviewComment(id)
    XCTAssertEqual(store.reviewComments.first?.body, "check bounds")
    XCTAssertNil(store.reviewComments.first?.editingText)
    store.beginReviewComment(anchor("other.swift"))
    store.cancelReviewComment(try XCTUnwrap(store.reviewComments.last?.id))
    XCTAssertEqual(store.reviewComments.count, 1)
    store.library.tasks = [.init(id: "task", project: "/app", title: "Other", runIDs: ["run"])]
    store.selection = "run"
    XCTAssertTrue(store.reviewComments.isEmpty)
    store.selection = nil
    XCTAssertEqual(store.reviewComments.count, 1)
    store.project = URL(fileURLWithPath: "/elsewhere")
    XCTAssertTrue(store.reviewComments.isEmpty)
    store.beginReviewComment(anchor())
    XCTAssertTrue(store.reviewComments.isEmpty)
    XCTAssertTrue(
      try JSONDecoder().decode(WorkspaceLibrary.self, from: Data("{}".utf8)).reviewComments.isEmpty)
  }

  @MainActor func testIndependentTaskWindowCommentsNeverFollowMainSelection() throws {
    let store = WorkspaceStore()
    store.project = URL(fileURLWithPath: "/main")
    store.library.tasks = [
      .init(id: "window", project: "/task", title: "Window", runIDs: []),
      .init(id: "main", project: "/main", title: "Main", runIDs: ["main-run"]),
    ]
    store.selection = "main-run"
    store.beginReviewComment(anchor("Task.swift", project: "/task"), taskID: "window")
    let id = try XCTUnwrap(store.reviewComments(taskID: "window").first?.id)
    store.updateReviewComment(id, text: "window review", taskID: "window")
    store.saveReviewComment(id, taskID: "window")

    XCTAssertTrue(store.reviewComments.isEmpty)
    XCTAssertEqual(store.reviewComments(taskID: "window").first?.body, "window review")
    store.selection = nil
    XCTAssertTrue(store.reviewComments.isEmpty)
    XCTAssertEqual(store.reviewComments(taskID: "window").count, 1)
    store.beginReviewComment(anchor("Wrong.swift", project: "/main"), taskID: "window")
    XCTAssertEqual(store.reviewComments(taskID: "window").count, 1)
  }

  @MainActor func testQueuedFeedbackIncludesSnapshotAndPreservesOtherTaskComments() async throws {
    let store = WorkspaceStore()
    store.project = URL(fileURLWithPath: "/app")
    store.connected = true
    let run = AgentRun(
      id: "run", kind: "chat", project: "/app", status: "running", createdAt: 0,
      updatedAt: 0, request: .null, result: nil)
    store.runs = [run]
    store.library.attach(run, to: nil, note: "First")
    store.selection = run.id
    store.beginReviewComment(anchor("quote\"\nfile.swift"))
    let id = try XCTUnwrap(store.reviewComments.first?.id)
    store.updateReviewComment(id, text: "Handle overflow")
    store.saveReviewComment(id)
    let saved = store.reviewComments
    store.library.reviewComments["other-task"] = saved
    store.draft = "Fix these comments"
    await store.sendDraft()
    XCTAssertTrue(store.reviewComments.isEmpty)
    XCTAssertTrue(store.draft.isEmpty)
    XCTAssertEqual(store.library.reviewComments["other-task"], saved)
    let message = try XCTUnwrap(store.library.queuedMessages.first)
    XCTAssertEqual(message.taskID, "run")
    XCTAssertTrue(message.text.hasPrefix("Fix these comments"))
    XCTAssertTrue(message.text.contains("Handle overflow"))
    let json = try XCTUnwrap(message.text.range(of: "\n["))
    let comments = try JSONDecoder().decode(
      [ReviewComment].self, from: Data(message.text[json.lowerBound...].utf8))
    XCTAssertEqual(comments, saved)
  }

  @MainActor func testFailedSendRetainsCommentsAndRequiresExplicitIntent() async throws {
    let store = WorkspaceStore()
    store.project = URL(fileURLWithPath: "/app")
    store.connected = true
    store.modelConfiguration.model = ""
    store.modelConfiguration.baseURL = "https://example.invalid/v1"
    store.beginReviewComment(anchor())
    let id = try XCTUnwrap(store.reviewComments.first?.id)
    store.updateReviewComment(id, text: "Check this")
    store.draft = "Fix"
    await store.sendDraft()
    XCTAssertTrue(store.error?.contains("保存") == true)
    store.saveReviewComment(id)
    store.draft = ""
    await store.sendDraft()
    XCTAssertTrue(store.error?.contains("说明") == true)
    store.draft = "Fix"
    await store.sendDraft()
    XCTAssertEqual(store.draft, "Fix")
    XCTAssertEqual(store.reviewComments.count, 1)
    XCTAssertTrue(store.library.chatRuns.isEmpty)
    XCTAssertTrue(store.error?.contains("配置") == true)
    store.action = .doctor
    await store.sendDraft()
    XCTAssertTrue(store.error?.contains("模型会话") == true)
    XCTAssertEqual(store.reviewComments.count, 1)
  }
}
