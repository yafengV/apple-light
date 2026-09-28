import XCTest
@testable import ShipiOS

private actor LastTurnReadGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var started = false
  func read(_ source: LastTurnReviewSource, root: URL) async throws -> LastTurnReviewSnapshot {
    started = true
    await withCheckedContinuation { continuation = $0 }
    return try LastTurnReviewSnapshot.load(source, dataRoot: root)
  }
  func hasStarted() -> Bool { started }
  func release() { continuation?.resume(); continuation = nil }
}

@MainActor final class LastTurnReviewTests: XCTestCase {
  private let patch = "diff --git a/file.txt b/file.txt\n--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-original\n+assistant\n"

  private func fixture() async throws -> (WorkspaceStore, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("last-turn-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    let root = GitBranchService.canonicalRoot(folder.appendingPathComponent("Project"))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Fixture"],
      ["config", "user.email", "fixture@example.invalid"]] {
      _ = try await GitReviewService.checked(args, at: root)
    }
    try Data("original\n".utf8).write(to: root.appendingPathComponent("file.txt"))
    _ = try await GitReviewService.checked(["add", "."], at: root)
    _ = try await GitReviewService.checked(["commit", "-qm", "Initial"], at: root)
    let store = WorkspaceStore(dataRoot: folder.appendingPathComponent("Data"))
    store.libraryLoaded = true
    store.scopeLoaded = true
    store.project = root
    store.workspace.root = root
    await store.workspace.refreshGit()
    return (store, root)
  }

  @discardableResult private func appendRun(_ store: WorkspaceStore, root: URL,
    taskID: String = "owner", diff: String?, kind: String = "chat",
    conversation: String? = nil) -> AgentRun {
    var request: [String: JSONValue] = ["api_protocol": .string("codexResponses")]
    if let conversation { request["conversation_kind"] = .string(conversation) }
    let run = AgentRun(id: UUID().uuidString, kind: kind, project: root.path,
      status: "succeeded", createdAt: Double(store.library.chatRuns.count), updatedAt: 0,
      request: .object(request), result: .object(["response": .string("Done")]))
    store.library.chatRuns.append(run)
    store.runs.append(run)
    if let index = store.library.tasks.firstIndex(where: { $0.id == taskID }) {
      store.library.tasks[index].runIDs.append(run.id)
    } else {
      store.library.tasks.append(.init(id: taskID, project: root.path, title: taskID, runIDs: [run.id]))
    }
    store.selection = run.id
    if let diff { store.recordCodexTurnDiff(runID: run.id,
      event: .object(["type": .string("turn_diff"), "unified_diff": .string(diff)])) }
    return store.library.chatRuns.last!
  }

  func testLastTurnUsesExactAssistantSnapshotRatherThanLaterWorkingTree() async throws {
    let (store, root) = try await fixture()
    let run = appendRun(store, root: root, diff: patch)
    try Data("user later\n".utf8).write(to: root.appendingPathComponent("file.txt"))
    try Data("unrelated\n".utf8).write(to: root.appendingPathComponent("user.txt"))
    store.workspace.reviewScope = .lastTurn
    await store.workspace.refreshGit()
    let snapshot = try XCTUnwrap(store.workspace.lastTurnReview)
    XCTAssertEqual(snapshot.source.runID, run.id)
    XCTAssertEqual(snapshot.unifiedDiff, patch)
    XCTAssertEqual(snapshot.files.map(\.path), ["file.txt"])
    XCTAssertEqual(snapshot.patches[0]?.additions, 1)
    XCTAssertFalse(store.workspace.diff.contains("user later"))
    XCTAssertFalse(store.workspace.canModifyReview)
    let oldIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    await store.workspace.stage("file.txt", undo: false)
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".git/index")), oldIndex)
  }

  func testMostRecentTurnWithoutDiffDoesNotFallBackToOlderChanges() async throws {
    let (store, root) = try await fixture()
    appendRun(store, root: root, diff: patch)
    let latest = appendRun(store, root: root, diff: nil)
    appendRun(store, root: root, diff: nil, conversation: "compact")
    store.workspace.reviewScope = .lastTurn
    await store.workspace.loadDiff()
    XCTAssertEqual(store.workspace.lastTurnReview?.source.runID, latest.id)
    XCTAssertTrue(store.workspace.lastTurnReview?.files.isEmpty == true)
    XCTAssertTrue(store.workspace.diff.isEmpty)
    XCTAssertNil(store.workspace.error)
  }

  func testStreamingUpdateAndClearReloadTheSameRun() async throws {
    let (store, root) = try await fixture()
    let run = appendRun(store, root: root, diff: patch)
    store.workspace.reviewScope = .lastTurn
    await store.workspace.loadDiff()
    let source = store.lastTurnReviewSource()
    let updated = patch.replacingOccurrences(of: "+assistant", with: "+newer assistant")
    store.recordCodexTurnDiff(runID: run.id, event: .object([
      "type": .string("turn_diff"), "unified_diff": .string(updated)]))
    XCTAssertNotEqual(store.lastTurnReviewSource(), source)
    await store.workspace.loadDiff()
    XCTAssertEqual(store.workspace.diff, updated)
    store.recordCodexTurnDiff(runID: run.id, event: .object([
      "type": .string("turn_diff"), "unified_diff": .string("")]))
    await store.workspace.loadDiff()
    XCTAssertTrue(store.workspace.lastTurnReview?.files.isEmpty == true)
    XCTAssertNil(store.workspace.error)
  }

  func testFullSnapshotBeyondPreviewAndCorruptionRetry() async throws {
    let (store, root) = try await fixture()
    let large = patch + String(repeating: " metadata\n", count: 30_000) + "tail retained\n"
    let run = appendRun(store, root: root, diff: large)
    let diff = try XCTUnwrap(run.codexTurnDiff)
    XCTAssertTrue(diff.truncated)
    store.workspace.reviewScope = .lastTurn
    await store.workspace.loadDiff()
    XCTAssertEqual(store.workspace.diff, large)
    XCTAssertTrue(store.workspace.lastTurnReview?.files[0].patch.hasSuffix("tail retained\n") == true)
    let location = store.dataRoot.appendingPathComponent("CodexTurnDiffs/\(diff.id.uuidString).patch")
    try Data("corrupt".utf8).write(to: location)
    await store.workspace.loadDiff()
    XCTAssertNil(store.workspace.lastTurnReview)
    XCTAssertTrue(store.workspace.error?.contains("校验失败") == true)
    XCTAssertTrue(store.workspace.diff.isEmpty)
    _ = try CodexTurnDiffStorage.save(large, id: diff.id, root: store.dataRoot)
    await store.workspace.refreshGit()
    XCTAssertNil(store.workspace.error)
    XCTAssertEqual(store.workspace.diff, large)
  }

  func testPathBaseCapturedAtSourceSubdirectoryAndPreservedAcrossMetadataChanges() async throws {
    let (store, root) = try await fixture()
    let child = root.appendingPathComponent("Child")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    let run = appendRun(store, root: child, diff: patch)
    XCTAssertEqual(run.codexTurnDiff?.pathBase, root.path)
    _ = try await GitReviewService.checked(["init", "-q"], at: child)
    store.recordCodexTurnDiff(runID: run.id, event: .object([
      "type": .string("turn_diff"), "unified_diff": .string(patch + "more metadata\n")]))
    XCTAssertEqual(store.library.chatRuns.last?.codexTurnDiff?.pathBase, root.path)
    let restored = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(restored.chatRuns.last?.codexTurnDiff?.pathBase, root.path)
  }

  func testTaskAndDetachedSourcesStayWithOwnerWhenMainSelectionChanges() async throws {
    let (store, root) = try await fixture()
    let first = appendRun(store, root: root, taskID: "first", diff: patch)
    let second = appendRun(store, root: root, taskID: "second",
      diff: patch.replacingOccurrences(of: "assistant", with: "second"))
    let resources = TaskWindowResources()
    resources.prepare("first", store: store)
    defer { resources.shutdown() }
    let task = try XCTUnwrap(resources.panels.tasks["first"]?.workspace)
    let detached = DetachedReviewSession()
    detached.configure(store: store, owner: "first")
    defer { detached.shutdown() }
    store.selection = second.id
    for workspace in [task, detached.workspace] {
      workspace.reviewScope = .lastTurn
      await workspace.loadDiff()
      XCTAssertEqual(workspace.lastTurnReview?.source.runID, first.id)
      XCTAssertEqual(workspace.diff, patch)
    }
    store.workspace.reviewScope = .lastTurn
    await store.workspace.loadDiff()
    XCTAssertEqual(store.workspace.lastTurnReview?.source.runID, second.id)
  }

  func testHistoricalCommentsRemainWithTaskAndOriginalSnapshotRoot() async throws {
    let (store, root) = try await fixture()
    let run = appendRun(store, root: root, diff: patch)
    let moved = root.deletingLastPathComponent().appendingPathComponent("Moved")
    try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
    store.project = moved
    store.workspace.root = moved
    store.library.tasks[0].project = moved.path
    let anchor = ReviewAnchor(project: moved.path, path: "file.txt", scope: "最近一轮",
      revision: run.id, fingerprint: ReviewDiff(patch).fingerprint, oldLine: nil, newLine: 1,
      code: "assistant", turnRunID: run.id, originRoot: root.path)
    store.beginReviewComment(anchor, taskID: "owner")
    let comment = try XCTUnwrap(store.reviewComments(taskID: "owner").first)
    store.updateReviewComment(comment.id, text: "Check the original change", taskID: "owner")
    store.saveReviewComment(comment.id, taskID: "owner")
    let prompt = try store.promptWithReviewComments("Follow up", comments: store.reviewComments(taskID: "owner"),
      project: moved.path, taskID: "owner")
    XCTAssertTrue(prompt.contains(root.path))
    XCTAssertTrue(prompt.contains(run.id))
    var wrong = anchor
    wrong.originRoot = moved.path
    store.beginReviewComment(wrong, taskID: "owner")
    XCTAssertEqual(store.reviewComments(taskID: "owner").count, 1)
    XCTAssertThrowsError(try store.promptWithReviewComments("Wrong task", comments: [comment],
      project: moved.path, taskID: "missing-owner"))
  }

  func testOldRequestCannotRestoreSnapshotAfterProjectChange() async throws {
    let (store, root) = try await fixture()
    appendRun(store, root: root, diff: patch)
    let gate = LastTurnReadGate()
    store.workspace.readLastTurnSnapshot = { source, data in try await gate.read(source, root: data) }
    store.workspace.reviewScope = .lastTurn
    let pending = Task { await store.workspace.loadDiff() }
    while !(await gate.hasStarted()) { await Task.yield() }
    store.workspace.setProject(nil)
    await gate.release()
    await pending.value
    XCTAssertNil(store.workspace.lastTurnReview)
    XCTAssertTrue(store.workspace.diff.isEmpty)
    XCTAssertFalse(store.workspace.reviewLoading)
  }

  func testLegacyRootAndScopeDecodeAndUnrecoverablePreviewError() async throws {
    let (store, root) = try await fixture()
    let old = CodexTurnDiff(id: UUID(), unifiedDiff: patch, truncated: false, changedFileCount: 1)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
    object.removeValue(forKey: "pathBase")
    let decoded = try JSONDecoder().decode(CodexTurnDiff.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertNil(decoded.pathBase)
    let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(decoded))
    let legacyRun = AgentRun(id: "legacy-run", kind: "chat", project: root.path,
      status: "succeeded", createdAt: 0, updatedAt: 0, request: .object([:]),
      result: .object(["codex_turn_diff": encoded]))
    XCTAssertNil(store.lastTurnReviewSource(for: legacyRun).root,
      "The current repository must not be used to guess an unrecorded historical base")
    let source = LastTurnReviewSource(runID: "legacy", root: root, diff: decoded)
    XCTAssertEqual(try LastTurnReviewSnapshot.load(source, dataRoot: store.dataRoot).unifiedDiff, patch)
    var truncated = decoded
    truncated.truncated = true
    XCTAssertThrowsError(try LastTurnReviewSnapshot.load(.init(runID: "legacy", root: root, diff: truncated), dataRoot: store.dataRoot))
    XCTAssertEqual(try JSONDecoder().decode(GitReviewScope.self,
      from: JSONEncoder().encode(GitReviewScope.lastTurn)), .lastTurn)
  }

  func testOldCardCannotOpenAfterOwnerChangesBeforeViewReload() async throws {
    let (store, root) = try await fixture()
    appendRun(store, root: root, taskID: "first", diff: patch)
    store.workspace.reviewScope = .lastTurn
    await store.workspace.loadDiff()
    let old = try XCTUnwrap(store.workspace.lastTurnReview)
    let file = try XCTUnwrap(old.files.first)
    appendRun(store, root: root, taskID: "second", diff: nil)
    store.workspace.fileOpenError = "Keep the new owner error"
    let request = store.workspace.fileOpenRequest
    await store.openLastTurnFile(file, snapshot: old, in: store.workspace)
    XCTAssertEqual(store.workspace.fileOpenRequest, request)
    XCTAssertEqual(store.workspace.fileOpenError, "Keep the new owner error")
    await store.workspace.loadDiff()
    XCTAssertNil(store.workspace.fileOpenError)
    XCTAssertTrue(store.workspace.lastTurnReview?.files.isEmpty == true)
  }

  func testRecordedScopeRestoresAndRejectsCommentsAfterSnapshotChanges() async throws {
    let (store, root) = try await fixture()
    let run = appendRun(store, root: root, diff: patch)
    let anchor = ReviewAnchor(project: root.path, path: "file.txt", scope: "最近一轮",
      revision: run.id, fingerprint: ReviewDiff(patch).fingerprint, oldLine: nil, newLine: 1,
      code: "assistant", turnRunID: run.id, originRoot: root.path)
    store.beginReviewComment(anchor, taskID: "owner")
    let id = try XCTUnwrap(store.reviewComments(taskID: "owner").first?.id)
    store.updateReviewComment(id, text: "Follow up", taskID: "owner")
    store.saveReviewComment(id, taskID: "owner")
    store.workspace.reviewScope = .lastTurn
    let layout = store.workspaceTabLayoutSnapshot
    XCTAssertEqual(try JSONDecoder().decode(WorkspaceTabLayout.self,
      from: JSONEncoder().encode(layout)).reviewScope, .lastTurn)
    store.recordCodexTurnDiff(runID: run.id, event: .object([
      "type": .string("turn_diff"), "unified_diff": .string(patch.replacingOccurrences(of: "assistant", with: "changed"))]))
    XCTAssertThrowsError(try store.promptWithReviewComments("Apply", comments: store.reviewComments(taskID: "owner"),
      project: root.path, taskID: "owner")) { error in
      XCTAssertTrue(error.localizedDescription.contains("快照已变化"))
    }
  }
}
