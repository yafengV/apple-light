import XCTest
@testable import ShipiOS

@MainActor final class WorkspaceVisibilityCommandTests: XCTestCase {
  private struct Reference: Decodable {
    struct State: Decodable {
      var mode: String
      var visible: Bool
      var focus: String
      var ids: [String]
      var selected: String?
    }
    struct Trace: Decodable { var initial: State; var states: [State] }
    var traces: [Trace]
  }
  private func reference() throws -> Reference {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "workspace_visibility_reference_713",
      withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
  }
  private func withStore(_ body: (WorkspaceStore) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    defer { store.workspace.browser.shutdown() }
    store.libraryLoaded = true; store.scopeLoaded = true
    store.library.tasks = ["a", "b"].map { .init(id: $0, project: "", title: $0, runIDs: []) }
    store.applyTaskSelection(store.library.tasks[0])
    try body(store)
  }

  func testMainVisibilityCommandMatchesPinnedReferenceWithRetainedNonBrowserContent() throws {
    for trace in try reference().traces where !trace.initial.ids.isEmpty {
      try withStore { store in
        store.workspaceTabs = trace.initial.ids.map { .file($0, owner: "a") }
        let content = store.workspaceTabs, selected = try XCTUnwrap(content.last)
        store.workspaceContentLayoutMode = trace.initial.mode == "full" ? .full : .split
        store.activateWorkspaceTab(selected.id)
        if trace.initial.focus == "chat" { store.activateChatTab() }
        store.showingInspector = trace.initial.visible && trace.initial.mode == "split"
        let unrelated = WorkspaceContentTab.sources(owner: "b")
        let bottom = WorkspaceContentTab.terminal(UUID(), owner: "a")
        let detached = WorkspaceContentTab.file("detached", owner: "a")
        store.workspaceTabs += [unrelated, bottom, detached]
        store.workspaceTabPlacements[bottom.id] = .bottom
        store.workspaceTabPlacements[detached.id] = .detached
        for expected in trace.states {
          store.executeCommand("browser")
          XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode, expected.mode == "full" ? .full : .split)
          XCTAssertEqual(store.showsWorkspaceInspector, expected.visible)
          XCTAssertEqual(store.activeRightWorkspaceContentTab?.id, expected.selected.map { WorkspaceContentTab.file($0, owner: "a").id })
          XCTAssertEqual(store.focusedWorkspaceContentTab?.id, expected.focus == "content" ? selected.id : nil)
          XCTAssertNil(store.activeWorkspaceContentTab)
          XCTAssertEqual(store.workspacePrimaryContentTabs, content)
          XCTAssertEqual(store.workspace.browser.tabs.count, 0, "Existing files must not create a browser")
          XCTAssertTrue(store.showingWorkspaceTabs, "Showing content is separate from hiding the tab strip")
        }
        XCTAssertTrue(store.workspaceTabs.contains(unrelated))
        XCTAssertTrue(store.workspaceTabs.contains(bottom))
        XCTAssertTrue(store.workspaceTabs.contains(detached))
      }
    }
  }

  func testTaskWindowVisibilityCommandMatchesSameReferenceAndKeepsOtherWindowIsolated() throws {
    for trace in try reference().traces where !trace.initial.ids.isEmpty {
      try withStore { store in
        let resources = TaskWindowResources(); resources.prepare("a", store: store)
        resources.prepare("b", store: store); defer { resources.shutdown() }
        let tabs = try XCTUnwrap(resources.tasks["a"]), other = try XCTUnwrap(resources.tasks["b"])
        tabs.openSources()
        if trace.initial.ids.count > 1 {
          XCTAssertTrue(tabs.openSubagents())
          tabs.backgroundTerminalTitle = { _ in "Retained output" }
          XCTAssertTrue(tabs.openBackgroundTerminal(UUID()))
        }
        let content = tabs.primaryContentTabs, selected = try XCTUnwrap(content.last)
        tabs.contentLayoutMode = trace.initial.mode == "full" ? .full : .split
        tabs.activate(selected.id)
        if trace.initial.focus == "chat" { tabs.activate(nil) }
        tabs.showingRight = trace.initial.visible && trace.initial.mode == "split"
        let otherLayout = other.layoutSnapshot
        for expected in trace.states {
          XCTAssertTrue(tabs.perform("browser"))
          XCTAssertEqual(tabs.effectiveContentLayoutMode, expected.mode == "full" ? .full : .split)
          XCTAssertEqual(tabs.showsContentSidePanel, expected.visible)
          XCTAssertEqual(tabs.selected(.right)?.id, expected.selected == nil ? nil : selected.id)
          XCTAssertEqual(tabs.focused?.id, expected.focus == "content" ? selected.id : nil)
          XCTAssertTrue(tabs.chatVisible)
          XCTAssertEqual(tabs.primaryContentTabs, content)
          XCTAssertTrue(tabs.browser.session.tabs.isEmpty)
          XCTAssertTrue(tabs.showingTabs)
          XCTAssertEqual(other.layoutSnapshot, otherLayout)
        }
      }
    }
  }

  func testEmptyWorkspaceCreatesOnlyOneSplitBrowserAndFullViewCommandWorksInEmptyTaskWindow() throws {
    try withStore { store in
      store.executeCommand("browser")
      let tab = try XCTUnwrap(store.activeRightWorkspaceContentTab)
      XCTAssertNotNil(tab.browserID)
      XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode, .split)
      XCTAssertEqual(store.focusedWorkspaceContentTab?.id, tab.id)
      store.workspaceTabs.append(.sources(owner: "a"))
      store.executeCommand("browser")
      XCTAssertFalse(store.showsWorkspaceInspector)
      store.executeCommand("browser")
      XCTAssertTrue(store.showsWorkspaceInspector)
      XCTAssertNil(store.focusedWorkspaceContentTab)
      XCTAssertEqual(store.workspace.browser.tabs.count, 1)
      XCTAssertEqual(store.workspacePrimaryContentTabs.count, 2)
      let resources = TaskWindowResources(); resources.prepare("a", store: store); defer { resources.shutdown() }
      let tabs = try XCTUnwrap(resources.tasks["a"])
      XCTAssertTrue(tabs.commandEnabled("workspace-view"))
      XCTAssertTrue(tabs.perform("workspace-view"))
      XCTAssertEqual(tabs.effectiveContentLayoutMode, .full)
      XCTAssertNotNil(tabs.selected(.left)?.browserID)
    }
  }

  func testVisibilityShortcutRemainsCustomizableAndUnavailableOutsideWorkspace() throws {
    try withStore { store in
      XCTAssertEqual(DesktopCommand.all.first { $0.id == "browser" }?.title, "循环切换工作空间布局")
      XCTAssertEqual(DesktopCommand.all.first { $0.id == "workspace-view" }?.title, "完整视图")
      XCTAssertEqual(DesktopCommand.all.first { $0.id == "workspace-tabs" }?.title, "显示或隐藏标签栏")
      XCTAssertEqual(store.shortcuts.binding("browser"), ShortcutBinding("⌘⇧B"))
      try store.shortcuts.set(ShortcutBinding("⌃⌥B"), for: "browser")
      XCTAssertEqual(store.shortcuts.binding("browser"), ShortcutBinding("⌃⌥B"))
      store.destination = .settings
      XCTAssertFalse(store.commandEnabled("browser"))
      store.executeCommand("browser")
      XCTAssertTrue(store.workspaceTabs.isEmpty)
      XCTAssertEqual(store.destination, .settings)
    }
  }

  func testFullChatRevealsLastPrimarySelectionInsteadOfStaleSplitSelectionInBothWindows() throws {
    try withStore { store in
      let first = WorkspaceContentTab.sources(owner: "a"), last = WorkspaceContentTab.subagents(owner: "a")
      store.workspaceTabs = [first, last]
      store.moveWorkspaceTab(first.id, to: .right)
      store.moveWorkspaceTab(last.id, to: .left)
      store.activateChatTab()
      store.executeCommand("browser")
      XCTAssertEqual(store.activeRightWorkspaceContentTab, last)
      XCTAssertNil(store.focusedWorkspaceContentTab)
      let resources = TaskWindowResources(); resources.prepare("a", store: store); defer { resources.shutdown() }
      let tabs = try XCTUnwrap(resources.tasks["a"])
      tabs.openSources(in: .right); XCTAssertTrue(tabs.openSubagents(in: .left))
      tabs.activate(nil)
      XCTAssertTrue(tabs.perform("browser"))
      XCTAssertEqual(tabs.selected(.right), last)
      XCTAssertNil(tabs.focused)
    }
  }

  func testRevealingRetainedBrowserDoesNotRequestAddressOrWebFocusFromChat() throws {
    try withStore { store in
      store.newBrowserTab(in: .right)
      let page = try XCTUnwrap(store.workspace.browser.selected)
      store.workspaceTabs.append(.sources(owner: "a"))
      store.executeCommand("browser")
      let address = store.workspace.browser.addressFocus, web = store.workspace.browser.contentFocus
      store.executeCommand("browser")
      XCTAssertEqual(store.workspace.browser.addressFocus, address)
      XCTAssertEqual(store.workspace.browser.contentFocus, web)
      XCTAssertNil(store.focusedWorkspaceContentTab)
      XCTAssertTrue(store.workspace.browser.selected === page)
      let resources = TaskWindowResources(); resources.prepare("a", store: store); defer { resources.shutdown() }
      let tabs = try XCTUnwrap(resources.tasks["a"])
      tabs.newBrowser(in: .right)
      let browserID = try XCTUnwrap(tabs.focusedID)
      tabs.openSources(in: .right); tabs.activate(browserID)
      XCTAssertTrue(tabs.perform("browser"))
      let taskPage = try XCTUnwrap(tabs.browser.session.selected)
      let taskAddress = tabs.browser.session.addressFocus, taskWeb = tabs.browser.session.contentFocus
      XCTAssertTrue(tabs.perform("browser"))
      XCTAssertEqual(tabs.browser.session.addressFocus, taskAddress)
      XCTAssertEqual(tabs.browser.session.contentFocus, taskWeb)
      XCTAssertNil(tabs.focused)
      XCTAssertTrue(tabs.browser.session.selected === taskPage)
    }
  }

  func testHiddenContentColdRestoreRetainsSelectionAndRevealsWithoutCreatingBrowser() throws {
    try withStore { store in
      let tab = WorkspaceContentTab.sources(owner: "a")
      store.workspaceTabs = [tab]; store.moveWorkspaceTab(tab.id, to: .right)
      store.executeCommand("browser")
      let saved = try JSONDecoder().decode(WorkspaceTabLayout.self, from: JSONEncoder().encode(store.workspaceTabLayoutSnapshot))
      let cold = WorkspaceStore(dataRoot: store.dataRoot.appendingPathComponent("cold"))
      defer { cold.workspace.browser.shutdown() }
      cold.libraryLoaded = true; cold.scopeLoaded = true; cold.library.tasks = store.library.tasks
      cold.selection = store.selection; cold.library.workspaceTabLayouts["a"] = saved
      cold.restoreWorkspaceTabLayout()
      XCTAssertFalse(cold.showsWorkspaceInspector)
      cold.executeCommand("browser")
      XCTAssertTrue(cold.showsWorkspaceInspector)
      XCTAssertEqual(cold.activeRightWorkspaceContentTab, tab)
      XCTAssertNil(cold.focusedWorkspaceContentTab)
      XCTAssertTrue(cold.workspace.browser.tabs.isEmpty)
      let resources = TaskWindowResources(); resources.prepare("a", store: store); defer { resources.shutdown() }
      let tabs = try XCTUnwrap(resources.tasks["a"])
      tabs.openSources(in: .right); XCTAssertTrue(tabs.perform("browser"))
      let taskSaved = try JSONDecoder().decode(TaskWindowTabLayout.self, from: JSONEncoder().encode(tabs.layoutSnapshot))
      let coldResources = TaskWindowResources(); coldResources.prepare("a", store: cold); defer { coldResources.shutdown() }
      let coldTabs = try XCTUnwrap(coldResources.tasks["a"]); coldTabs.restoreLayout(taskSaved)
      XCTAssertFalse(coldTabs.showsContentSidePanel)
      XCTAssertTrue(coldTabs.perform("browser"))
      XCTAssertTrue(coldTabs.showsContentSidePanel)
      XCTAssertEqual(coldTabs.selected(.right), tab)
      XCTAssertNil(coldTabs.focused)
      XCTAssertTrue(coldTabs.browser.session.tabs.isEmpty)
    }
  }
}
