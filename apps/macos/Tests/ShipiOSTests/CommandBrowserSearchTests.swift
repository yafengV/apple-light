import XCTest
@testable import ShipiOS

final class CommandBrowserSearchTests: XCTestCase {
  func testBrowserMatchingRequiresEveryWordAcrossTitlePageAndURLAndCapsTen() {
    let tabs = (0..<12).map { index in
      CommandBrowserResult(id: "\(index)", owner: "task", title: "API Guide", pageTitle: "模型配置",
        url: "https://example.test/docs/\(index)", ownerTitle: "Not searchable")
    }
    XCTAssertTrue(CommandBrowserResult.search(tabs, query: " \n ").isEmpty)
    XCTAssertEqual(CommandBrowserResult.search(tabs, query: " API\n模型配置  EXAMPLE ").map(\.id), (0..<10).map(String.init))
    XCTAssertTrue(CommandBrowserResult.search(tabs, query: "API missing").isEmpty)
    XCTAssertTrue(CommandBrowserResult.search(tabs, query: "Not searchable").isEmpty)
    XCTAssertEqual(CommandBrowserResult.search(tabs, query: "docs/11").map(\.id), ["11"])
  }

  func testTabEntersSearchGroupsThenCyclesAndResetsWithQuery() {
    let groups = [["browser-a", "browser-b"], ["task-a", "task-b"]]
    XCTAssertEqual(CommandSearchSections.next("task-b", groups: groups, continuing: false, reverse: false), "browser-a")
    XCTAssertEqual(CommandSearchSections.next("browser-b", groups: groups, continuing: false, reverse: true), "task-a")
    XCTAssertEqual(CommandSearchSections.next("browser-b", groups: groups, continuing: true, reverse: false), "task-a")
    XCTAssertEqual(CommandSearchSections.next("task-b", groups: groups, continuing: true, reverse: false), "browser-a")
    XCTAssertEqual(CommandSearchSections.next("browser-a", groups: groups, continuing: true, reverse: true), "task-a")
    XCTAssertEqual(CommandSearchSections.next("command", groups: groups, continuing: true, reverse: true), "task-a")
    XCTAssertNil(CommandSearchSections.next(nil, groups: [[], ["task-a"]], continuing: false, reverse: false))
  }

  @MainActor func testBrowserResultOpensOwnerAndPaneWithoutChangingDraftsAndRejectsClosedOrDetachedTabs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.library.tasks = [
      .init(id: "a", project: "", title: "A", runIDs: ["a"]),
      .init(id: "b", project: "", title: "B", runIDs: ["b"])]
    store.library.drafts = ["a": "A draft", "b": "B draft", "new:none": "Unsent draft"]
    store.applyTaskSelection(store.library.tasks[0])
    store.newBrowserTab(in: .right)
    let result = try XCTUnwrap(store.commandBrowserTabs.first)
    let browserID = try XCTUnwrap(store.workspace.browser.selected?.id)
    store.applyTaskSelection(store.library.tasks[1])
    let opened = await store.openCommandBrowserTab(result)
    XCTAssertTrue(opened)
    XCTAssertEqual(store.selectedTask?.id, "a")
    XCTAssertEqual(store.activeRightWorkspaceTabID, result.id)
    XCTAssertEqual(store.focusedWorkspaceTabID, result.id)
    XCTAssertEqual(store.workspace.browser.addressFocusTarget, browserID)
    XCTAssertEqual(store.library.drafts, ["a": "A draft", "b": "B draft", "new:none": "Unsent draft"])

    store.workspaceTabPlacements[result.id] = .detached
    XCTAssertTrue(store.commandBrowserTabs.isEmpty)
    let detachedOpened = await store.openCommandBrowserTab(result)
    XCTAssertFalse(detachedOpened)
    store.workspaceTabPlacements[result.id] = .right
    store.closeBrowserTab(browserID)
    let closedOpened = await store.openCommandBrowserTab(result)
    XCTAssertFalse(closedOpened)

    store.newTask()
    store.newBrowserTab()
    let draftResult = try XCTUnwrap(store.commandBrowserTabs.first)
    store.applyTaskSelection(store.library.tasks[1])
    let draftOpened = await store.openCommandBrowserTab(draftResult)
    XCTAssertTrue(draftOpened)
    XCTAssertNil(store.selectedTask)
    XCTAssertEqual(store.draft, "Unsent draft")
    XCTAssertEqual(store.activeWorkspaceTabID, draftResult.id)
    await store.shutdown()
  }

  @MainActor func testSearchReturningToUnsentDraftSelectsContentWithoutDiscardingItsTarget() async throws {
    for mode in [WorkspaceContentLayoutMode.full, .split] {
      for address in [String?.none, "", "search draft"] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WorkspaceStore(dataRoot: root)
        await store.restore()
        store.library.tasks = [.init(id: "other", project: "", title: "Other", runIDs: [])]
        store.library.drafts = ["new:none": "Unsent input", "other": "Other input"]
        store.newTask()
        store.newBrowserTab(in: mode == .full ? .left : .right)
        let page = try XCTUnwrap(store.workspace.browser.selected)
        if let address { page.setAddressDraft(address) }
        let result = try XCTUnwrap(store.commandBrowserTabs.first)
        let owner = store.currentWorkspaceTabOwner
        store.applyTaskSelection(store.library.tasks[0])
        XCTAssertFalse(page.closed)
        let opened = await store.openCommandBrowserTab(result)
        XCTAssertTrue(opened, "\(mode)/\(String(describing: address))")
        XCTAssertFalse(page.closed)
        XCTAssertEqual(store.currentWorkspaceTabOwner, owner)
        XCTAssertEqual(store.focusedWorkspaceTabID, result.id)
        XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode, mode)
        XCTAssertTrue(store.workspace.browser.selected === page)
        XCTAssertEqual(page.address, address ?? "")
        XCTAssertEqual(store.library.drafts, ["new:none": "Unsent input", "other": "Other input"])
        XCTAssertFalse(store.canReopenClosedWorkspaceTab)
        XCTAssertFalse(store.workspace.browser.canReopenClosedTab)
        await store.shutdown()
        try? FileManager.default.removeItem(at: root)
      }
    }
  }

  @MainActor func testDraftContentRevealRejectsUnavailableOrForeignTargetsBeforeChangingSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.library.tasks = [.init(id: "task", project: "", title: "Task", runIDs: [])]
    store.newTask(); store.newBrowserTab()
    let result = try XCTUnwrap(store.commandBrowserTabs.first), page = try XCTUnwrap(store.workspace.browser.selected)
    store.applyTaskSelection(store.library.tasks[0])
    let origin = store.currentTaskLocation, history = store.navigationBack
    for place in [WorkspaceTabPlacement.detached, .bottom] {
      store.workspaceTabPlacements[result.id] = place
      let opened = await store.selectWorkspaceDraft(result.owner, revealingContentTabID: result.id)
      XCTAssertFalse(opened); XCTAssertEqual(store.currentTaskLocation, origin)
      XCTAssertEqual(store.navigationBack, history); XCTAssertFalse(page.closed)
    }
    store.workspaceTabPlacements[result.id] = .left
    store.newBrowserTab()
    let foreign = try XCTUnwrap(store.activeWorkspaceTabID)
    for target in ["missing", foreign] {
      let opened = await store.selectWorkspaceDraft(result.owner, revealingContentTabID: target)
      XCTAssertFalse(opened); XCTAssertEqual(store.currentTaskLocation, origin)
      XCTAssertEqual(store.navigationBack, history); XCTAssertFalse(page.closed)
    }
    store.closeBrowserTab(page.id)
    let closed = await store.selectWorkspaceDraft(result.owner, revealingContentTabID: result.id)
    XCTAssertFalse(closed); XCTAssertEqual(store.currentTaskLocation, origin)
    await store.shutdown()
  }
}
