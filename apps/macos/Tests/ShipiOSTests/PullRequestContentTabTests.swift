import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class PullRequestContentTabTests: XCTestCase {
  private func pr(_ number: Int = 42, title: String = "Feature") -> GitHubPullRequest {
    .init(number: number, url: "https://github.com/sample/project/pull/\(number)", title: title,
      isDraft: false, headRefName: "feature", baseRefName: "main", isCrossRepository: false, state: "OPEN")
  }
  private func fixture() throws -> WorkspaceStore {
    _ = NSApplication.shared
    let root = GitBranchService.canonicalRoot(FileManager.default.temporaryDirectory)
      .appendingPathComponent("pr-tabs-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("state"))
    store.libraryLoaded = true; store.scopeLoaded = true; store.connected = true
    store.library.tasks = [.init(id: "a", project: root.path, title: "A", runIDs: []),
      .init(id: "b", project: root.path, title: "B", runIDs: [])]
    store.library.taskPullRequests = ["a": [pr()], "b": [pr()]]
    store.project = root; store.workspace.setProject(root); store.selection = "a"
    store.restoreWorkspaceTabLayout()
    addTeardownBlock { @MainActor in
      store.workspace.browser.shutdown(); store.workspace.terminals.shutdown()
      try? FileManager.default.removeItem(at: root)
    }
    return store
  }
  private func cold(_ original: WorkspaceStore) throws -> WorkspaceStore {
    let result = WorkspaceStore(dataRoot: original.dataRoot)
    result.library = try WorkspaceLibrary.load(from: original.dataRoot.appendingPathComponent("workspace.json"))
    result.libraryLoaded = true; result.scopeLoaded = true; result.connected = true
    result.project = original.project; result.workspace.setProject(result.project); result.selection = "a"
    result.restoreWorkspaceTabLayout()
    addTeardownBlock { @MainActor in result.workspace.browser.shutdown(); result.workspace.terminals.shutdown() }
    return result
  }
  private func window(_ store: WorkspaceStore, id: String = "window") -> TaskWindowResources {
    let result = TaskWindowResources(); result.prepare("a", store: store, windowID: id)
    addTeardownBlock { @MainActor in result.shutdown() }; return result
  }

  func testDefaultRightReusePreservesPlacementAndSeparatesOwners() throws {
    let store = try fixture(), tab = WorkspaceContentTab.pullRequest(pr().url, owner: "a")
    XCTAssertTrue(store.openPullRequestContent(pr()))
    XCTAssertEqual(store.activeRightWorkspaceContentTab, tab)
    store.moveWorkspaceTab(tab.id, to: .left)
    XCTAssertTrue(store.openPullRequestContent(pr(), mergeConfirmation: true))
    XCTAssertEqual(store.activeWorkspaceContentTab, tab)
    XCTAssertEqual(store.workspaceTabs, [tab]); XCTAssertNotNil(store.pullRequestTabPresentations.token(tab.id))
    store.applyTaskSelection(store.library.tasks[1])
    XCTAssertTrue(store.openPullRequestContent(pr()))
    XCTAssertEqual(store.workspaceTabs.count, 2)
    XCTAssertNotEqual(store.activeRightWorkspaceContentTab?.id, tab.id)
  }

  func testCloseReopenKeepsPlacementAndDropsConfirmation() throws {
    let store = try fixture(), tab = WorkspaceContentTab.pullRequest(pr().url, owner: "a")
    XCTAssertTrue(store.openPullRequestContent(pr(), in: .left, mergeConfirmation: true))
    store.closeWorkspaceTab(tab.id)
    XCTAssertNil(store.pullRequestTabPresentations.token(tab.id)); XCTAssertTrue(store.canReopenClosedWorkspaceTab)
    store.reopenClosedWorkspaceTab()
    XCTAssertEqual(store.activeWorkspaceContentTab, tab)
    XCTAssertNil(store.pullRequestTabPresentations.token(tab.id))
  }

  func testDiskRestorationAndPinnedOpenNeverReplayConfirmation() async throws {
    let store = try fixture(), tab = WorkspaceContentTab.pullRequest(pr().url, owner: "a")
    XCTAssertTrue(store.openPullRequestContent(pr(), mergeConfirmation: true))
    store.moveWorkspaceTab(tab.id, to: .left); store.pinWorkspaceTab(tab.id); store.saveLibrary()
    let restored = try cold(store), pin = try XCTUnwrap(restored.library.pinnedContentTabs.first)
    XCTAssertEqual(restored.activeWorkspaceContentTab, tab)
    XCTAssertNil(restored.pullRequestTabPresentations.token(tab.id))
    XCTAssertEqual(pin.kind, .pullRequest); XCTAssertEqual(pin.restoreURL, pr().url)
    restored.closeWorkspaceTab(tab.id); await restored.openPinnedWorkspaceTab(pin.id)
    XCTAssertEqual(restored.workspaceTabs, [tab]); XCTAssertEqual(restored.activeRightWorkspaceContentTab, tab)
    XCTAssertNil(restored.pullRequestTabPresentations.token(tab.id))
  }

  func testInvalidSavedIdentityAndRemovedRecordAreNotRestored() throws {
    let store = try fixture()
    XCTAssertTrue(store.openPullRequestContent(pr())); store.saveLibrary()
    store.library.workspaceTabLayouts["a"]?.tabs[0].committedURL = pr(99).url
    try store.library.save(to: store.dataRoot.appendingPathComponent("workspace.json"))
    let invalid = try cold(store); XCTAssertTrue(invalid.workspaceTabs.isEmpty)
    store.library.taskPullRequests["a"] = []; store.saveLibrary()
    let missing = try cold(store); XCTAssertTrue(missing.workspaceTabs.isEmpty)
    XCTAssertFalse(missing.openPullRequestContent(pr()))
  }

  func testDetachedRestorationKeepsOwnerWithoutChangingSelection() throws {
    let store = try fixture(), tab = WorkspaceContentTab.pullRequest(pr().url, owner: "a")
    XCTAssertTrue(store.openPullRequestContent(pr()))
    store.moveWorkspaceTab(tab.id, to: .detached); store.saveLibrary()
    let route = try XCTUnwrap(store.detachedWorkspaceTabRoute(tab.id))
    let restored = try cold(store); restored.applyTaskSelection(restored.library.tasks[1])
    XCTAssertEqual(restored.detachedWorkspaceTabRestoration(route), .ready("a"))
    XCTAssertNotNil(restored.prepareDetachedWorkspaceTab(route)); XCTAssertEqual(restored.selection, "b")
    XCTAssertNil(restored.pullRequestTabPresentations.token(tab.id))
    restored.library.taskPullRequests["a"] = []
    restored.workspaceTabs.removeAll { $0.id == tab.id }
    XCTAssertEqual(restored.detachedWorkspaceTabRestoration(route), .close)
  }

  func testTaskWindowOpenRestoreAndReopenDoNotChangeMainDraftOrTask() throws {
    let store = try fixture(); store.applyTaskSelection(store.library.tasks[1]); store.draft = "Main draft"
    let resources = window(store), tabs = try XCTUnwrap(resources.tasks["a"])
    let tab = WorkspaceContentTab.pullRequest(pr().url, owner: "a")
    XCTAssertTrue(tabs.openPullRequest(pr(), mergeConfirmation: true))
    XCTAssertEqual(tabs.selected(.right), tab); tabs.move(tab.id, to: .left)
    XCTAssertTrue(tabs.openPullRequest(pr())); XCTAssertEqual(tabs.selected(.left), tab)
    XCTAssertEqual(store.selection, "b"); XCTAssertEqual(store.draft, "Main draft")
    tabs.close(tab.id); tabs.reopen(); XCTAssertEqual(tabs.selected(.left), tab)
    XCTAssertNil(tabs.pullRequestPresentations.token(tab.id)); store.saveLibrary()
    let loaded = try cold(store), restored = window(loaded)
    let result = try XCTUnwrap(restored.tasks["a"])
    XCTAssertEqual(result.tabs, [tab]); XCTAssertEqual(result.selected(.left), tab)
    XCTAssertNil(result.pullRequestPresentations.token(tab.id))
  }

  func testTaskWindowProjectChangeAndMissingRecordInvalidatePRTabs() throws {
    let store = try fixture(), resources = window(store), tabs = try XCTUnwrap(resources.tasks["a"])
    XCTAssertTrue(tabs.openPullRequest(pr(), mergeConfirmation: true))
    store.library.tasks[0].project += "/changed"; resources.prepare("a", store: store)
    XCTAssertTrue(tabs.tabs.isEmpty); XCTAssertFalse(tabs.canReopen)
    store.library.taskPullRequests["a"] = []
    XCTAssertFalse(tabs.openPullRequest(pr()))
  }

  func testPrepareRejectsInvalidURLsAndUsesOwningTaskForNewRecord() throws {
    let store = try fixture(); store.applyTaskSelection(store.library.tasks[1])
    XCTAssertTrue(store.preparePullRequestContent(pr(99), taskID: "a"))
    XCTAssertEqual(store.library.taskPullRequests["a"]?.first?.number, 99)
    XCTAssertEqual(store.library.taskPullRequests["b"], [pr()])
    let invalid = GitHubPullRequest(number: 100, url: "https://example.invalid/pull/100", title: "Invalid",
      isDraft: false, headRefName: "feature", baseRefName: "main", isCrossRepository: false)
    XCTAssertFalse(store.preparePullRequestContent(invalid, taskID: "a"))
    XCTAssertFalse(store.preparePullRequestContent(pr(), taskID: "missing"))
    store.library.tasks[0].project = ""
    XCTAssertFalse(store.preparePullRequestContent(pr(), taskID: "a"))
  }

  func testIndependentDetailPreparationRemainsAvailableWhileMainScopeIsBusy() throws {
    let store = try fixture(); store.applyTaskSelection(store.library.tasks[1]); store.busy = true
    XCTAssertFalse(store.canSelectTask(store.library.tasks[0]))
    XCTAssertTrue(store.preparePullRequestContent(pr(99), taskID: "a"))
    let resources = window(store), tabs = try XCTUnwrap(resources.tasks["a"])
    XCTAssertTrue(tabs.openPullRequest(pr(99), mergeConfirmation: true))
    XCTAssertEqual(store.selection, "b"); XCTAssertEqual(tabs.selected(.right)?.pullRequestURL, pr(99).url)
    store.busy = false
  }

  func testTitleFallbackAndEphemeralTokenConsumptionProtectNewRequests() throws {
    let store = try fixture(), request = pr(title: "  "), tab = WorkspaceContentTab.pullRequest(request.url, owner: "a")
    store.library.taskPullRequests["a"] = [request]
    XCTAssertEqual(store.workspaceTabTitle(tab), "Pull request #42")
    let presentations = PullRequestTabPresentations(); presentations.request(tab.id)
    let old = try XCTUnwrap(presentations.token(tab.id)); presentations.request(tab.id)
    let new = try XCTUnwrap(presentations.token(tab.id)); presentations.consume(tab.id, token: old)
    XCTAssertEqual(presentations.token(tab.id), new); presentations.consume(tab.id, token: new)
    XCTAssertNil(presentations.token(tab.id))
  }
}
