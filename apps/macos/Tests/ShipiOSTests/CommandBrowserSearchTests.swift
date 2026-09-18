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
}
