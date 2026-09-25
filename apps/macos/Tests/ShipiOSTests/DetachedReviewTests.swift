import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class DetachedReviewTests: XCTestCase {
  private func fixture() throws -> (WorkspaceStore, URL, URL) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("detached-review-\(UUID())")
    let a = GitBranchService.canonicalRoot(root.appendingPathComponent("A"))
    let b = GitBranchService.canonicalRoot(root.appendingPathComponent("B"))
    for path in [a, b] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true; store.scopeLoaded = true; store.connected = true
    store.project = a; store.workspace.setProject(a)
    store.library.tasks = [.init(id: "a", project: a.path, title: "A", runIDs: []),
      .init(id: "b", project: b.path, title: "B", runIDs: [])]
    store.selection = "a"
    store.restoreWorkspaceTabLayout()
    store.workspaceTabs = [.review(owner: "a")]
    store.workspaceTabPlacements["review:a"] = .detached
    store.saveLibrary()
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return (store, a, b)
  }
  private func switchMain(_ store: WorkspaceStore, to b: URL) {
    store.captureWorkspaceTabLayout()
    store.project = b; store.workspace.setProject(b)
    store.applyTaskSelection(store.library.tasks[1])
  }
  private func anchor(_ root: URL) -> ReviewAnchor {
    .init(project: root.path, path: "File.swift", scope: "未暂存", revision: "working tree",
      fingerprint: "fixture", oldLine: 1, newLine: 1, code: "let value = 2")
  }

  func testMainProjectSwitchCannotRetargetDetachedReviewOrItsComments() throws {
    let (store, a, b) = try fixture(), review = DetachedReviewSession()
    review.configure(store: store, owner: "a")
    defer { review.shutdown() }
    XCTAssertFalse(review.workspace === store.workspace)
    switchMain(store, to: b)
    review.configure(store: store, owner: "a")
    XCTAssertEqual(review.workspace.root?.path, a.path)
    XCTAssertEqual(store.workspace.root, b)
    store.beginReviewComment(anchor(a), taskID: "a")
    let comment = try XCTUnwrap(store.reviewComments(taskID: "a").first)
    store.updateReviewComment(comment.id, text: "A comment", taskID: "a")
    store.saveReviewComment(comment.id, taskID: "a")
    XCTAssertEqual(store.reviewComments(taskID: "a").first?.body, "A comment")
    XCTAssertTrue(store.reviewComments(taskID: "b").isEmpty)
    XCTAssertEqual(store.selection, "b")
  }

  func testScopePersistsToOwnerWithoutChangingOtherTasksReview() throws {
    let (store, _, b) = try fixture(), review = DetachedReviewSession()
    review.configure(store: store, owner: "a")
    defer { review.shutdown() }
    review.workspace.reviewScope = .staged
    review.saveScope(store: store)
    XCTAssertEqual(store.workspace.reviewScope, .staged)
    switchMain(store, to: b)
    store.workspace.reviewScope = .unstaged
    review.workspace.reviewScope = .branch
    review.saveScope(store: store)
    XCTAssertEqual(store.workspace.reviewScope, .unstaged)
    let disk = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(disk.workspaceTabLayouts["a"]?.reviewScope, .branch)
    let reopened = DetachedReviewSession()
    reopened.configure(store: store, owner: "a")
    XCTAssertEqual(reopened.workspace.reviewScope, .branch)
    reopened.shutdown()
  }

  func testExplicitMissingOwnerAndProjectlessDraftCannotUseCurrentProjectForComments() throws {
    let (store, a, _) = try fixture(), review = DetachedReviewSession()
    review.configure(store: store, owner: "a")
    store.library.tasks.removeAll { $0.id == "a" }
    review.configure(store: store, owner: "a")
    XCTAssertNil(review.workspace.root)
    store.beginReviewComment(anchor(a), taskID: "a")
    store.beginReviewComment(anchor(a), taskID: "new:none")
    XCTAssertTrue(store.library.reviewComments.isEmpty)
    XCTAssertNil(store.workspaceTabProject(owner: "missing"))
  }

  func testDraftReviewCommentsRemainInOriginalProjectAfterMainSwitch() throws {
    let (store, a, b) = try fixture(), review = DetachedReviewSession()
    let owner = "new:" + a.path
    review.configure(store: store, owner: owner)
    defer { review.shutdown() }
    switchMain(store, to: b)
    review.configure(store: store, owner: owner)
    XCTAssertEqual(review.workspace.root?.path, a.path)
    store.beginReviewComment(anchor(a), taskID: owner)
    XCTAssertEqual(store.reviewComments(taskID: owner).count, 1)
    store.beginReviewComment(anchor(b), taskID: owner)
    XCTAssertEqual(store.reviewComments(taskID: owner).count, 1)
    XCTAssertTrue(store.reviewComments.isEmpty)
  }

  func testChangingOwnerProjectClearsPriorDiffAndScope() throws {
    let (store, a, b) = try fixture(), review = DetachedReviewSession()
    review.configure(store: store, owner: "a")
    review.workspace.diff = "old diff"
    review.workspace.showingCommitPush = true
    store.library.tasks[0].project = b.path
    review.configure(store: store, owner: "a")
    XCTAssertEqual(review.workspace.root?.path, b.path)
    XCTAssertNotEqual(review.workspace.root, a)
    XCTAssertTrue(review.workspace.diff.isEmpty)
    XCTAssertFalse(review.workspace.showingCommitPush)
    review.shutdown()
    XCTAssertNil(review.workspace.root)
  }

  func testStagingUsesDetachedRepositoryAfterMainProjectSwitch() async throws {
    let (store, a, b) = try fixture(), review = DetachedReviewSession()
    defer { review.shutdown() }
    for root in [a, b] {
      _ = try await GitReviewService.checked(["init"], at: root)
      try "let value = 1\n".write(to: root.appendingPathComponent("File.swift"), atomically: true, encoding: .utf8)
      _ = try await GitReviewService.checked(["add", "File.swift"], at: root)
      _ = try await GitReviewService.checked(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "Initial"], at: root)
      try "let value = 2\n".write(to: root.appendingPathComponent("File.swift"), atomically: true, encoding: .utf8)
    }
    review.configure(store: store, owner: "a")
    switchMain(store, to: b)
    await review.workspace.refreshGit()
    await review.workspace.stage("File.swift", undo: false)
    XCTAssertNil(review.workspace.error)
    let stagedA = try await GitReviewService.checked(["diff", "--cached", "--name-only"], at: a)
    let stagedB = try await GitReviewService.checked(["diff", "--cached", "--name-only"], at: b)
    XCTAssertTrue(stagedA.contains("File.swift"))
    XCTAssertTrue(stagedB.isEmpty)
    XCTAssertEqual(store.selection, "b")
  }
}
