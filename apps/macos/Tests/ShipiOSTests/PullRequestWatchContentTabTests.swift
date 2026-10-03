import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class PullRequestWatchContentTabTests: XCTestCase {
  private let request = GitHubPullRequest(number: 42,
    url: "https://github.com/sample/project/pull/42", title: "Feature", isDraft: false,
    headRefName: "feature", baseRefName: "main", isCrossRepository: false, state: "OPEN")

  private func fixture() throws -> (WorkspaceStore, ShipAutomation) {
    _ = NSApplication.shared
    let root = GitBranchService.canonicalRoot(FileManager.default.temporaryDirectory)
      .appendingPathComponent("watch-tabs-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("state"))
    store.libraryLoaded = true; store.scopeLoaded = true; store.connected = true; store.automationsLoaded = true
    store.library.tasks = [
      .init(id: "source", project: root.path, title: "Source", runIDs: []),
      .init(id: "watch", project: root.path, title: "PR watch", runIDs: []),
      .init(id: "other", project: root.path, title: "Other", runIDs: [])]
    store.library.taskPullRequests = ["source": [request], "watch": [request]]
    store.project = root; store.workspace.setProject(root); store.selection = "source"
    store.restoreWorkspaceTabLayout(); store.draft = "source draft"
    var watch = ShipAutomation()
    watch.name = "Watch and fix PR #42"; watch.prompt = "Watch this PR"; watch.project = root.path
    watch.projects = [root.path]; watch.taskID = "watch"; watch.execution = .worktree
    watch.watchedPullRequest = request; watch.cadence = .custom; watch.customRule = "FREQ=MINUTELY;INTERVAL=10"
    watch.scheduleAnchor = .now; watch.nextRun = Date().addingTimeInterval(600)
    guard store.saveAutomation(watch) else { throw AgentFailure(message: store.automationsError ?? "Save failed") }
    addTeardownBlock { @MainActor in
      store.taskWindowResources.allObjects.forEach { $0.shutdown() }
      store.workspace.browser.shutdown(); store.workspace.terminals.shutdown()
      try? FileManager.default.removeItem(at: root)
    }
    return (store, watch)
  }
  private func cold(_ store: WorkspaceStore, loadAutomations: Bool = true) throws -> WorkspaceStore {
    let result = WorkspaceStore(dataRoot: store.dataRoot)
    result.library = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    result.libraryLoaded = true; result.scopeLoaded = true; result.connected = true
    result.project = store.project; result.workspace.setProject(result.project); result.selection = "source"
    if loadAutomations {
      result.automationPreferences = try AutomationStorage.load(root: store.dataRoot)
      result.automationsLoaded = true
    }
    result.restoreWorkspaceTabLayout()
    addTeardownBlock { @MainActor in
      result.taskWindowResources.allObjects.forEach { $0.shutdown() }
      result.workspace.browser.shutdown(); result.workspace.terminals.shutdown()
    }
    return result
  }
  private func window(_ store: WorkspaceStore) throws -> TaskWindowTabs {
    let resource = TaskWindowResources()
    resource.prepare("source", store: store, windowID: "window")
    addTeardownBlock { @MainActor in resource.shutdown() }
    return try XCTUnwrap(resource.tasks["source"])
  }
  private func tab(_ watch: ShipAutomation) -> WorkspaceContentTab {
    .pullRequestWatch(watch.id, task: "watch", owner: "source")
  }

  func testDefaultRightRepeatedOpenPreservesPlacementAndSourceDraft() throws {
    let (store, watch) = try fixture(), tab = tab(watch)
    store.setTaskWindowDraft("watch draft", taskID: "watch")
    XCTAssertTrue(store.openPullRequestWatchProgress(watch))
    XCTAssertEqual(store.activeRightWorkspaceContentTab, tab)
    XCTAssertEqual(store.selection, "source"); XCTAssertEqual(store.draft, "source draft")
    store.moveWorkspaceTab(tab.id, to: .left)
    XCTAssertTrue(store.openPullRequestWatchProgress(watch))
    XCTAssertEqual(store.activeWorkspaceContentTab, tab); XCTAssertEqual(store.workspaceTabs, [tab])
    XCTAssertEqual(store.taskWindowDraft("watch"), "watch draft")
    store.closeWorkspaceTab(tab.id)
    XCTAssertTrue(try XCTUnwrap(store.pullRequestWatch(for: request)).enabled)
    store.reopenClosedWorkspaceTab()
    XCTAssertEqual(store.activeWorkspaceContentTab, tab)
  }

  func testPausedProgressAndPinnedDiskRoundTripPreserveIdentity() async throws {
    let (store, watch) = try fixture(), tab = tab(watch)
    store.pausePullRequestWatch(request)
    XCTAssertTrue(store.openPullRequestWatchProgress(watch))
    store.moveWorkspaceTab(tab.id, to: .left); store.pinWorkspaceTab(tab.id); store.saveLibrary()
    let result = try cold(store), pin = try XCTUnwrap(result.library.pinnedContentTabs.first)
    XCTAssertEqual(result.activeWorkspaceContentTab, tab)
    XCTAssertEqual(pin.watchAutomationID, watch.id); XCTAssertEqual(pin.watchTaskID, "watch")
    XCTAssertFalse(try XCTUnwrap(result.pullRequestWatchContent(tab)).enabled)
    result.closeWorkspaceTab(tab.id); await result.openPinnedWorkspaceTab(pin.id)
    XCTAssertEqual(result.activeRightWorkspaceContentTab, tab)
    XCTAssertEqual(result.selection, "source"); XCTAssertEqual(result.draft, "source draft")
  }

  func testRemovedOrMismatchedWatchAndArchivedTargetCannotRestore() throws {
    let (store, watch) = try fixture()
    XCTAssertTrue(store.openPullRequestWatchProgress(watch)); store.saveLibrary()
    var invalid = store.library
    invalid.workspaceTabLayouts["source"]?.tabs[0].watchAutomationID = UUID()
    try invalid.save(to: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertTrue(try cold(store).workspaceTabs.isEmpty)
    invalid = store.library; invalid.workspaceTabLayouts["source"]?.tabs[0].watchTaskID = "other"
    try invalid.save(to: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertTrue(try cold(store).workspaceTabs.isEmpty)
    invalid = store.library; invalid.tasks[1].archived = true
    try invalid.save(to: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertTrue(try cold(store).workspaceTabs.isEmpty)
    store.automationPreferences.items = []
    XCTAssertNil(store.pullRequestWatchContent(tab(watch)))
  }

  func testRestoreWaitsForAutomationLoadWithoutOverwritingSavedLayout() async throws {
    let (store, watch) = try fixture(), tab = tab(watch)
    XCTAssertTrue(store.openPullRequestWatchProgress(watch)); store.saveLibrary()
    let result = try cold(store, loadAutomations: false)
    XCTAssertTrue(result.workspaceTabs.isEmpty)
    result.saveLibrary()
    XCTAssertEqual(result.library.workspaceTabLayouts["source"]?.tabs.first?.id, tab.id)
    await result.loadAutomations()
    XCTAssertEqual(result.activeRightWorkspaceContentTab, tab)
  }

  func testTaskWindowRestoreWaitsForAutomationsAndDoesNotChangeMainSelection() async throws {
    let (store, watch) = try fixture(), tabs = try window(store), tab = tab(watch)
    XCTAssertTrue(tabs.openPullRequestWatch(watch)); tabs.move(tab.id, to: .left)
    store.saveLibrary()
    let result = try cold(store, loadAutomations: false)
    result.selection = "other"; result.draft = "other draft"
    let restored = try window(result)
    XCTAssertTrue(restored.tabs.isEmpty)
    result.saveLibrary()
    XCTAssertEqual(result.library.taskWindowTabLayouts["window"]?["source"]?.content.tabs.first?.id, tab.id)
    await result.loadAutomations()
    XCTAssertEqual(restored.selected(.left), tab)
    restored.close(tab.id); restored.reopen()
    XCTAssertEqual(restored.selected(.left), tab)
    XCTAssertEqual(result.selection, "other"); XCTAssertEqual(result.draft, "other draft")
    XCTAssertTrue(try XCTUnwrap(result.pullRequestWatchContent(tab)).enabled)
  }

  func testDetachedRestorationValidatesWatchWithoutChangingMainTask() throws {
    let (store, watch) = try fixture(), tab = tab(watch)
    XCTAssertTrue(store.openPullRequestWatchProgress(watch)); store.moveWorkspaceTab(tab.id, to: .detached)
    store.saveLibrary()
    let route = try XCTUnwrap(store.detachedWorkspaceTabRoute(tab.id)), result = try cold(store)
    result.selection = "other"
    XCTAssertEqual(result.detachedWorkspaceTabRestoration(route), .ready("source"))
    XCTAssertNotNil(result.prepareDetachedWorkspaceTab(route)); XCTAssertEqual(result.selection, "other")
    result.automationPreferences.items = []
    XCTAssertEqual(result.detachedWorkspaceTabRestoration(route), .close)
  }

  func testLoadingWatchRestorationDoesNotDiscardContentOpenedInTheMeantime() async throws {
    let (store, watch) = try fixture(), tabs = try window(store), tab = tab(watch)
    XCTAssertTrue(tabs.openPullRequestWatch(watch)); store.saveLibrary()
    let result = try cold(store, loadAutomations: false), restored = try window(result)
    restored.newBrowser()
    let selected = restored.focusedID
    await result.loadAutomations()
    XCTAssertEqual(restored.focusedID, selected)
    XCTAssertTrue(restored.tabs.contains(tab)); XCTAssertEqual(restored.tabs.count, 2)
    XCTAssertEqual(restored.placement(tab.id), .right)
  }

  func testToastProgressActionAndReplacedToastSafety() async throws {
    let (store, watch) = try fixture(), tab = tab(watch)
    store.notices.show(id: "watch", title: "Started", level: .info,
      taskID: "source", watchAutomationID: watch.id, watchTaskID: "watch")
    let notice = try XCTUnwrap(store.notices.items.first)
    XCTAssertEqual(notice.actionTitle, "查看进度")
    XCTAssertTrue(store.workspaceTabs.isEmpty)
    await store.openNoticeTask(notice)
    XCTAssertEqual(store.activeRightWorkspaceContentTab, tab)
    XCTAssertEqual(store.selection, "source"); XCTAssertEqual(store.draft, "source draft")
    store.closeWorkspaceTab(tab.id)
    store.notices.show(id: "watch", title: "Paused", level: .info)
    await store.openNoticeTask(notice)
    XCTAssertTrue(store.workspaceTabs.isEmpty)
    XCTAssertEqual(store.notices.items.first?.title, "Paused")
  }

  func testNewAutomationForRetainedTargetReusesSingleTabAndPlacement() throws {
    let (store, watch) = try fixture(), old = tab(watch)
    XCTAssertTrue(store.openPullRequestWatchProgress(watch)); store.moveWorkspaceTab(old.id, to: .left)
    var replacement = watch; replacement.id = UUID()
    store.automationPreferences.items = [replacement]
    XCTAssertTrue(store.openPullRequestWatchProgress(replacement))
    XCTAssertEqual(store.workspaceTabs, [tab(replacement)])
    XCTAssertEqual(store.workspaceTabPlacement(old.id), .left)
    XCTAssertNil(store.pullRequestWatchContent(old))
  }

  func testNativeProgressAtSidePanelWidthEditsOnlyTargetComposer() async throws {
    let (store, watch) = try fixture()
    store.setTaskWindowDraft("watch draft", taskID: "watch")
    let view = PullRequestWatchProgressView(store: store, tab: tab(watch), close: {})
    let host = NSHostingView(rootView: view.frame(width: 430, height: 680))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 680),
      styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.contentView = nil; window.close() }
    try await Task.sleep(for: .milliseconds(700)); host.layoutSubtreeIfNeeded()
    func editors(_ view: NSView) -> [ComposerNativeTextView] {
      ((view as? ComposerNativeTextView).map { [$0] } ?? []) + view.subviews.flatMap(editors)
    }
    let editor = try XCTUnwrap(editors(host).first)
    XCTAssertEqual(editor.string, "watch draft")
    editor.selectAll(nil); editor.insertText("monitor guidance", replacementRange: editor.selectedRange())
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(store.taskWindowDraft("watch"), "monitor guidance")
    XCTAssertEqual(store.selection, "source"); XCTAssertEqual(store.draft, "source draft")
    XCTAssertEqual(host.frame.width, 430, accuracy: 1)
    XCTAssertEqual(window.title, "", "Embedded content must not replace the source window title")
    if let directory = ProcessInfo.processInfo.environment["SHIPIOS_SETTINGS_SNAPSHOTS"] {
      let root = URL(fileURLWithPath: directory)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        .write(to: root.appendingPathComponent("pr-watch-progress.png"))
    }
  }
}
