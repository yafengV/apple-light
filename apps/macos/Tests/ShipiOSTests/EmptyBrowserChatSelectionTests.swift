import XCTest
@testable import ShipiOS

@MainActor final class EmptyBrowserChatSelectionTests: XCTestCase {
  private struct Reference: Decodable {
    struct Case: Decodable {
      var name: String; var handled: Bool; var mode: WorkspaceContentLayoutMode
      var visible: Bool; var focus: String; var ids: [String]
    }
    var cases: [Case]
  }
  private func reference() throws -> [Reference.Case] {
    let url = try XCTUnwrap(Bundle.module.url(forResource:"chat_empty_browser_reference_715", withExtension:"json", subdirectory:"Fixtures"))
    return try JSONDecoder().decode(Reference.self, from:Data(contentsOf:url)).cases
  }
  private func withStore(_ body:(WorkspaceStore)throws->Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let store = WorkspaceStore(dataRoot:root)
    defer { store.workspace.browser.shutdown() }
    store.libraryLoaded = true; store.scopeLoaded = true
    store.library.tasks = ["a", "b"].map { .init(id:$0, project:"", title:$0, runIDs:[]) }
    store.applyTaskSelection(store.library.tasks[0])
    try body(store)
  }
  private func protect(_ page:BrowserTab, state:String) {
    switch state {
    case "address-draft": page.setAddressDraft("input")
    case "cleared-address-draft": page.setAddressDraft("")
    case "zoom": page.view.pageZoom = 1.5
    case "agent": page.agentOperationActive = true
    default: break
    }
  }
  func testMainFullChatSelectionMatchesActualReferenceForSupportedStates() throws {
    let supported = Set(["empty", "address-draft", "cleared-address-draft", "pinned", "multiple", "zoom", "agent"])
    for sample in try reference() where supported.contains(sample.name) {
      try withStore { store in
        store.newBrowserTab()
        let page = try XCTUnwrap(store.workspace.browser.selected)
        protect(page, state:sample.name)
        if sample.name == "pinned" { store.pinWorkspaceTab(try XCTUnwrap(store.activeWorkspaceTabID)) }
        if sample.name == "multiple" { store.newBrowserTab() }
        let focus = store.focusComposer
        store.activateChatTab()
        XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode, sample.mode, sample.name)
        XCTAssertEqual(store.workspacePrimaryContentTabs.count, sample.ids.count, sample.name)
        XCTAssertEqual(page.closed, sample.ids.isEmpty, sample.name)
        XCTAssertEqual(store.showsWorkspaceInspector, sample.visible, sample.name)
        XCTAssertNil(store.focusedWorkspaceContentTab)
        XCTAssertNil(store.activeWorkspaceContentTab)
        XCTAssertNotEqual(store.focusComposer, focus)
        XCTAssertFalse(store.canReopenClosedWorkspaceTab)
        XCTAssertFalse(store.workspace.browser.canReopenClosedTab)
      }
    }
  }
  func testTaskFullChatSelectionMatchesActualReferenceForSupportedStates() throws {
    let supported = Set(["empty", "address-draft", "cleared-address-draft", "pinned", "multiple", "zoom", "agent"])
    for sample in try reference() where supported.contains(sample.name) {
      try withStore { store in
        let resources = TaskWindowResources(); resources.prepare("a", store:store); defer { resources.shutdown() }
        let tabs = try XCTUnwrap(resources.tasks["a"])
        tabs.newBrowser()
        let page = try XCTUnwrap(tabs.browser.session.selected)
        protect(page, state:sample.name)
        if sample.name == "pinned" { resources.pin(try XCTUnwrap(tabs.focusedID), taskID:"a") }
        if sample.name == "multiple" { tabs.newBrowser() }
        let focus = tabs.chatFocus
        tabs.activate(nil)
        XCTAssertEqual(tabs.effectiveContentLayoutMode, sample.mode, sample.name)
        XCTAssertEqual(tabs.primaryContentTabs.count, sample.ids.count, sample.name)
        XCTAssertEqual(page.closed, sample.ids.isEmpty, sample.name)
        XCTAssertEqual(tabs.showsContentSidePanel, sample.visible, sample.name)
        XCTAssertNil(tabs.focused)
        XCTAssertNil(tabs.selected(.left))
        XCTAssertNotEqual(tabs.chatFocus, focus)
        XCTAssertFalse(tabs.canReopen)
        XCTAssertFalse(tabs.browser.session.canReopenClosedTab)
      }
    }
  }
  func testNumericAndAdjacentNavigationToChatDiscardEmptyPageInBothWindows() throws {
    for command in ["focus-tab-1", "next-tab", "previous-tab"] {
      try withStore { store in
        store.newBrowserTab()
        let page = try XCTUnwrap(store.workspace.browser.selected)
        store.executeCommand(command)
        XCTAssertTrue(page.closed, command)
        XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode, .split)
        XCTAssertNil(store.focusedWorkspaceContentTab)
        let resources = TaskWindowResources(); resources.prepare("a", store:store); defer { resources.shutdown() }
        let tabs = try XCTUnwrap(resources.tasks["a"])
        tabs.newBrowser()
        let other = try XCTUnwrap(tabs.browser.session.selected)
        XCTAssertTrue(tabs.perform(command))
        XCTAssertTrue(other.closed, command)
        XCTAssertEqual(tabs.effectiveContentLayoutMode, .split)
        XCTAssertNil(tabs.focused)
      }
    }
  }
  func testSplitChatSelectionKeepsVisibleEmptyPageUntilHideCommand() throws {
    try withStore { store in
      store.newBrowserTab(in:.right)
      let page = try XCTUnwrap(store.workspace.browser.selected)
      store.activateChatTab()
      XCTAssertFalse(page.closed)
      XCTAssertTrue(store.showsWorkspaceInspector)
      let resources = TaskWindowResources(); resources.prepare("a", store:store); defer { resources.shutdown() }
      let tabs = try XCTUnwrap(resources.tasks["a"])
      tabs.newBrowser(in:.right)
      let other = try XCTUnwrap(tabs.browser.session.selected)
      tabs.activate(nil)
      XCTAssertFalse(other.closed)
      XCTAssertTrue(tabs.showsContentSidePanel)
    }
  }
  func testReturnedSplitLayoutIsSavedAndRestoresWithoutDiscardUndoInBothWindows() throws {
    try withStore { store in
      store.newBrowserTab(); store.activateChatTab()
      // The close callback saves immediately; no later layout save may repair it.
      let disk = try WorkspaceLibrary.load(from:store.dataRoot.appendingPathComponent("workspace.json"))
      let saved = try XCTUnwrap(disk.workspaceTabLayouts["a"])
      XCTAssertEqual(saved.contentLayoutMode, .split)
      XCTAssertTrue(saved.tabs.isEmpty)
      let cold = WorkspaceStore(dataRoot:store.dataRoot.appendingPathComponent("cold"))
      defer { cold.workspace.browser.shutdown() }
      cold.libraryLoaded = true; cold.scopeLoaded = true; cold.library = disk; cold.selection = "a"
      cold.restoreWorkspaceTabLayout()
      XCTAssertEqual(cold.effectiveWorkspaceContentLayoutMode, .split)
      XCTAssertTrue(cold.workspacePrimaryContentTabs.isEmpty)
      let resources = TaskWindowResources(); resources.prepare("a", store:store); defer { resources.shutdown() }
      let tabs = try XCTUnwrap(resources.tasks["a"])
      tabs.newBrowser(); tabs.activate(nil)
      let layout = try JSONDecoder().decode(TaskWindowTabLayout.self, from:JSONEncoder().encode(tabs.layoutSnapshot))
      resources.prepare("b", store:store)
      let other = try XCTUnwrap(resources.tasks["b"]); other.restoreLayout(layout)
      XCTAssertEqual(other.effectiveContentLayoutMode, .split)
      XCTAssertTrue(other.primaryContentTabs.isEmpty)
      XCTAssertFalse(other.canReopen)
    }
  }
}
