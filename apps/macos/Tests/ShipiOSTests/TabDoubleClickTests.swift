import XCTest
@testable import ShipiOS

@MainActor final class TabDoubleClickTests: XCTestCase {
  private struct Reference: Decodable {
    struct State: Decodable {
      var mode: WorkspaceContentLayoutMode; var visible: Bool; var focus: String
      var ids: [String]; var selected: String?; var target: String?
    }
    struct Trace: Decodable { var initial: State; var result: State }
    var traces: [Trace]
  }
  private func traces() throws -> [Reference.Trace] {
    let url = try XCTUnwrap(Bundle.module.url(forResource:"tab_double_click_reference_716", withExtension:"json", subdirectory:"Fixtures"))
    let traces = try JSONDecoder().decode(Reference.self, from:Data(contentsOf:url)).traces
    XCTAssertEqual(traces.count, 22)
    return traces
  }
  private func withStore(_ body:(WorkspaceStore,URL)throws->Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:root, withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:root) }
    for id in ["content-1","content-2","content-3"] { try Data(id.utf8).write(to:root.appendingPathComponent(id)) }
    let store = WorkspaceStore(dataRoot:root.appendingPathComponent("state"))
    defer { store.workspace.browser.shutdown() }
    store.libraryLoaded = true; store.scopeLoaded = true
    store.library.tasks = ["a","b"].map { .init(id:$0, project:root.path, title:$0, runIDs:[]) }
    store.applyTaskSelection(store.library.tasks[0])
    try body(store,root)
  }
  private func logical(_ tab:WorkspaceContentTab) -> String {
    if case .file(let path,_) = tab { return path }
    return "new-browser"
  }
  func testMainMatchesActualDoubleClickHandlerAcrossFullSplitHiddenAndEmptyStates() throws {
    for sample in try traces() {
      try withStore { store,_ in
        store.workspaceTabs = sample.initial.ids.map { .file($0,owner:"a") }
        store.workspaceContentLayoutMode = sample.initial.mode
        if let selected = sample.initial.selected { store.activateWorkspaceTab(WorkspaceContentTab.file(selected,owner:"a").id) }
        if sample.initial.focus == "chat" { store.activateChatTab() }
        store.showingInspector = sample.initial.visible
        store.toggleWorkspaceTabLayout(sample.initial.target == "content" ? store.workspaceTabs.first?.id : nil)
        XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode,sample.result.mode)
        XCTAssertEqual(store.workspacePrimaryContentTabs.map(logical),sample.result.ids)
        XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode == .full ? store.activeWorkspaceContentTab != nil : store.showsWorkspaceInspector,sample.result.visible)
        XCTAssertEqual(store.focusedWorkspaceContentTab == nil ? "chat":"content",sample.result.focus)
        let retained = store.focusedWorkspaceContentTab ?? store.workspacePrimaryContentTabs.first { $0.id == store.lastWorkspaceContentTabID }
        XCTAssertEqual(retained.map(logical),sample.result.selected)
      }
    }
  }
  func testTaskMatchesActualDoubleClickHandlerAcrossFullSplitHiddenAndEmptyStates() throws {
    for sample in try traces() {
      try withStore { store,_ in
        let resources = TaskWindowResources(); resources.prepare("a",store:store); defer { resources.shutdown() }
        let tabs = try XCTUnwrap(resources.tasks["a"])
        for path in sample.initial.ids { tabs.openFile(path) }
        tabs.contentLayoutMode = sample.initial.mode
        if let selected = sample.initial.selected { tabs.activate(WorkspaceContentTab.file(selected,owner:"a").id) }
        if sample.initial.focus == "chat" { tabs.activate(nil) }
        tabs.showingRight = sample.initial.visible
        tabs.toggleTabLayout(sample.initial.target == "content" ? tabs.primaryContentTabs.first?.id : nil)
        XCTAssertEqual(tabs.effectiveContentLayoutMode,sample.result.mode)
        XCTAssertEqual(tabs.primaryContentTabs.map(logical),sample.result.ids)
        XCTAssertEqual(tabs.effectiveContentLayoutMode == .full ? !tabs.chatVisible : tabs.showsContentSidePanel,sample.result.visible)
        XCTAssertEqual(tabs.focused == nil ? "chat":"content",sample.result.focus)
        let retained = tabs.focused ?? tabs.primaryContentTabs.first { $0.id == tabs.lastContentForCommand }
        XCTAssertEqual(retained.map(logical),sample.result.selected)
      }
    }
  }
  func testBottomDetachedOtherOwnerAndMissingTargetsCannotTogglePrimaryLayout() throws {
    try withStore { store,_ in
      store.workspaceTabs = [.sources(owner:"a"),.subagents(owner:"a"),.sources(owner:"b")]
      store.workspaceTabPlacements[store.workspaceTabs[1].id] = .detached
      store.activateWorkspaceTab(store.workspaceTabs[0].id)
      for id in [store.workspaceTabs[1].id,store.workspaceTabs[2].id,"missing"] {
        let snapshot = store.workspaceTabLayoutSnapshot
        store.toggleWorkspaceTabLayout(id)
        XCTAssertEqual(store.workspaceTabLayoutSnapshot,snapshot)
      }
      store.destination = .settings
      store.toggleWorkspaceTabLayout(nil)
      XCTAssertEqual(store.destination,.settings)
      XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode,.full)
      let resources = TaskWindowResources(); resources.prepare("a",store:store); defer { resources.shutdown() }
      let tabs = try XCTUnwrap(resources.tasks["a"])
      tabs.openSources()
      tabs.newTerminal(in:.bottom)
      let bottom = try XCTUnwrap(tabs.selected(.bottom))
      for id in [bottom.id,"missing"] {
        let snapshot = tabs.layoutSnapshot
        tabs.toggleTabLayout(id)
        XCTAssertEqual(tabs.layoutSnapshot,snapshot)
      }
    }
  }
}
