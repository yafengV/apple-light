import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class ComposerWorktreeBranchLoadingTests: XCTestCase {
  func testRestoredWorktreeComposerLoadsBranchesWhenRepositoryBecomesReady() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("composer-branches-\(UUID())")
    let project = root.appendingPathComponent("Project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for args in [["init", "-q", "-b", "main"], ["config", "user.name", "ShipiOS Test"],
      ["config", "user.email", "test@example.invalid"], ["commit", "--allow-empty", "-qm", "Fixture"]] {
      _ = try await GitReviewService.checked(args, at: project)
    }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    store.project = project
    store.newTaskExecution = .worktree
    store.workspace.gitAvailable = false
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 700),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let catalog = GitBranchCatalog()
    let host = NSHostingView(rootView: ComposerView(store: store, branchCatalog: catalog))
    window.contentView = host
    defer { window.contentView = nil; window.close() }
    try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
    XCTAssertNil(catalog.snapshot)
    store.workspace.gitAvailable = true
    for _ in 0..<320 {
      try await Task.sleep(for: .milliseconds(25)); host.layoutSubtreeIfNeeded()
      if catalog.snapshot != nil { break }
    }
    XCTAssertEqual(catalog.snapshot?.currentName, "main", "Async Git readiness must load the restored worktree branch picker")
    XCTAssertEqual(catalog.snapshot?.branches.map(\.name), ["main"])
    XCTAssertNil(catalog.error)
    XCTAssertEqual(store.newTaskExecution, .worktree, "No manual environment toggle is required")
    _ = try XCTUnwrap(catalog.snapshot)
    store.library.tasks = [.init(id: "history", project: project.path, title: "History", runIDs: ["history-run"])]
    store.selection = "history-run"
    try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
    _ = try await GitReviewService.checked(["branch", "feature"], at: project)
    store.selection = nil
    for _ in 0..<320 {
      try await Task.sleep(for: .milliseconds(25)); host.layoutSubtreeIfNeeded()
      if catalog.snapshot?.branches.contains(where: { $0.name == "feature" }) == true { break }
    }
    XCTAssertEqual(Set(catalog.snapshot?.branches.map(\.name) ?? []), ["main", "feature"],
      "Returning from history must refresh branch choices in the retained composer")
    XCTAssertFalse(window.isVisible, "Lifecycle regression only; formal window verification is separate")
    let snapshot = try await GitBranchService.snapshot(at: project)
    XCTAssertEqual(snapshot.currentName, "main")
    XCTAssertEqual(snapshot.changedFiles, 0)
  }
}
