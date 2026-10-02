import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class GitReviewModeTests: XCTestCase {
  func testLastTurnOnlyModeKeepsSelectedGitScopeAndPreventsReviewMutation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.workspace.selectedReviewScope = .branch
    XCTAssertEqual(store.workspace.reviewScope, .branch)

    var preferences = store.library.gitPreferences
    preferences.disableGitBasedReview = true
    XCTAssertTrue(store.saveGitPreferences(preferences))
    XCTAssertEqual(store.workspace.reviewScope, .lastTurn)
    XCTAssertEqual(store.workspace.selectedReviewScope, .branch)
    XCTAssertEqual(store.workspaceTabLayoutSnapshot.reviewScope, .branch)
    XCTAssertFalse(store.workspace.canModifyReview)
    XCTAssertTrue(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
      .gitPreferences.disableGitBasedReview)

    preferences.disableGitBasedReview = false
    XCTAssertTrue(store.saveGitPreferences(preferences))
    XCTAssertEqual(store.workspace.reviewScope, .branch)
    XCTAssertEqual(store.workspace.selectedReviewScope, .branch)
  }

  func testLegacyPreferencesDefaultToFullReviewAndSearchFindsGitSwitch() throws {
    let legacy = try JSONDecoder().decode(GitPreferences.self,
      from: Data(#"{"branchPrefix":"codex/"}"#.utf8))
    XCTAssertFalse(legacy.disableGitBasedReview)
    let result = try XCTUnwrap(SettingsSearch.results(for: "关闭基于 Git 的审查")
      .first { $0.field == .disableGitBasedReview })
    XCTAssertEqual(result.page, .git)
  }

  func testOpenTaskWindowReviewFollowsModeWithoutLosingItsOwnScope() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    let sessions = TaskWindowPanelSessions()
    let panel = sessions.panels(for: "task", project: root.path)
    store.additionalTaskWindowPanels.add(sessions)
    store.bindGitReviewPolicy(to: panel.workspace, taskID: "task")
    panel.workspace.selectedReviewScope = .commit

    var preferences = store.library.gitPreferences
    preferences.disableGitBasedReview = true
    XCTAssertTrue(store.saveGitPreferences(preferences))
    XCTAssertEqual(panel.workspace.reviewScope, .lastTurn)
    XCTAssertEqual(panel.workspace.selectedReviewScope, .commit)
    XCTAssertFalse(panel.workspace.canModifyReview)

    preferences.disableGitBasedReview = false
    XCTAssertTrue(store.saveGitPreferences(preferences))
    XCTAssertEqual(panel.workspace.reviewScope, .commit)
  }

  func testReviewPanelOnlyOffersLastTurnWhenGitReviewDisabled() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.workspace.root = root
    store.workspace.gitAvailable = true
    store.workspace.gitBranch = "main"
    store.workspace.selectedReviewScope = .staged
    store.library.gitPreferences.disableGitBasedReview = true
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 800),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: GitReviewView(store: store, workspace: store.workspace))
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    host.layoutSubtreeIfNeeded()

    XCTAssertEqual(store.workspace.reviewScope, .lastTurn)
    let popups = findPopups(host)
    let scope = try XCTUnwrap(popups.first { !$0.itemTitles.isEmpty })
    XCTAssertEqual(scope.itemTitles, ["最近一轮"])

    var preferences = store.library.gitPreferences
    preferences.disableGitBasedReview = false
    XCTAssertTrue(store.saveGitPreferences(preferences))
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    XCTAssertEqual(store.workspace.reviewScope, .staged)
    XCTAssertEqual(scope.itemTitles, GitReviewScope.allCases.map(\.title))
  }

  private func findPopups(_ view: NSView) -> [NSPopUpButton] {
    (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(findPopups)
  }
}
