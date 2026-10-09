import XCTest
@testable import ShipiOS

@MainActor final class WorkspaceFullViewTests: XCTestCase {
  private struct Reference: Decodable {
    struct State: Decodable {
      var mode: WorkspaceContentLayoutMode; var visible: Bool; var focus: String
      var ids: [String]; var selected: String?; var target: String?
    }
    struct Trace: Decodable { var initial: State; var result: State }
    var traces: [Trace]
  }
  private func traces() throws -> [Reference.Trace] {
    let url = try XCTUnwrap(Bundle.module.url(forResource:"workspace_full_view_reference_718", withExtension:"json", subdirectory:"Fixtures"))
    let traces = try JSONDecoder().decode(Reference.self, from:Data(contentsOf:url)).traces
    XCTAssertEqual(traces.count, 12)
    return traces
  }
  private func withStore(_ body:(WorkspaceStore,URL)throws->Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:root, withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:root) }
    for id in ["content-1","content-2","content-3"] { try Data(id.utf8).write(to:root.appendingPathComponent(id)) }
    let store = WorkspaceStore(dataRoot:root.appendingPathComponent("state"))
    defer { store.workspace.browser.shutdown(); store.workspace.terminals.shutdown() }
    store.libraryLoaded = true; store.scopeLoaded = true
    store.library.tasks = ["a","b"].map { .init(id:$0, project:root.path, title:$0, runIDs:[]) }
    store.applyTaskSelection(store.library.tasks[0])
    try body(store,root)
  }
  private func logical(_ tab:WorkspaceContentTab) -> String {
    if case .file(let path,_) = tab { return path }
    return "new-browser"
  }
  func testMainMatchesActualFullViewTransitions() throws {
    for sample in try traces() {
      try withStore { store,_ in
        store.workspaceTabs = sample.initial.ids.map { .file($0,owner:"a") }
        store.workspaceContentLayoutMode = sample.initial.mode
        if let selected = sample.initial.selected { store.activateWorkspaceTab(WorkspaceContentTab.file(selected,owner:"a").id) }
        if sample.initial.focus == "chat" { store.activateChatTab() }
        store.showingInspector = sample.initial.visible
        store.toggleWorkspaceTabView()
        XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode,sample.result.mode)
        XCTAssertEqual(store.workspacePrimaryContentTabs.map(logical),sample.result.ids)
        XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode == .full ? store.activeWorkspaceContentTab != nil : store.showsWorkspaceInspector,sample.result.visible)
        XCTAssertEqual(store.focusedWorkspaceContentTab == nil ? "chat":"content",sample.result.focus)
        let retained = store.focusedWorkspaceContentTab ?? store.workspacePrimaryContentTabs.first { $0.id == store.lastWorkspaceContentTabID }
        XCTAssertEqual(retained.map(logical),sample.result.selected)
      }
    }
  }
  func testTaskMatchesActualFullViewTransitions() throws {
    for sample in try traces() {
      try withStore { store,_ in
        let resources = TaskWindowResources(); resources.prepare("a",store:store); defer { resources.shutdown() }
        let tabs = try XCTUnwrap(resources.tasks["a"])
        for path in sample.initial.ids { tabs.openFile(path) }
        tabs.contentLayoutMode = sample.initial.mode
        if let selected = sample.initial.selected { tabs.activate(WorkspaceContentTab.file(selected,owner:"a").id) }
        if sample.initial.focus == "chat" { tabs.activate(nil) }
        tabs.showingRight = sample.initial.visible
        tabs.toggleFullWidth()
        XCTAssertEqual(tabs.effectiveContentLayoutMode,sample.result.mode)
        XCTAssertEqual(tabs.primaryContentTabs.map(logical),sample.result.ids)
        XCTAssertEqual(tabs.effectiveContentLayoutMode == .full ? !tabs.chatVisible : tabs.showsContentSidePanel,sample.result.visible)
        XCTAssertEqual(tabs.focused == nil ? "chat":"content",sample.result.focus)
        let retained = tabs.focused ?? tabs.primaryContentTabs.first { $0.id == tabs.lastContentForCommand }
        XCTAssertEqual(retained.map(logical),sample.result.selected)
      }
    }
  }
  func testToolbarPropertiesMatchActualComponentsAndCountTypography() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "workspace_full_view_reference_718", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let policies = try XCTUnwrap(fixture["policies"] as? [[String: Any]])
    XCTAssertEqual(policies.count, 15)
    for state in policies {
      let count = try XCTUnwrap(state["count"] as? Int), display = try XCTUnwrap(state["display"] as? String)
      let menu = WorkspaceLayoutMenu(entries: (0..<count).map { .init(id: String($0), title: String($0), icon: "doc") },
        contentVisible: display != "chat", home: false, layoutMode: display == "full" ? .full : .split)
      let full = try XCTUnwrap(state["full"] as? [String: Any])
      XCTAssertEqual(menu.fullViewVisible, full["pressed"] as? Bool)
      XCTAssertEqual(menu.fullViewVisible ? "collapse" : "expand", full["icon"] as? String)
      if let main = state["main"] as? [String: Any] {
        XCTAssertEqual(menu.toolbarPressed, main["pressed"] as? Bool)
        XCTAssertEqual(menu.toolbarArtwork.glyph == .columns ? "column" : "stack", main["icon"] as? String)
      }
      // A hidden saved full layout also displays the enter action.
      if display == "chat" {
        var hidden = menu; hidden.layoutMode = .full
        XCTAssertEqual(hidden.fullViewLabel, "进入完整视图")
        XCTAssertFalse(hidden.fullViewVisible)
      }
    }
    for sample in try XCTUnwrap(fixture["counts"] as? [[String: Any]]) {
      let count = try XCTUnwrap(sample["count"] as? Int)
      let artwork = WorkspaceLayoutToolbarArtwork(glyph: .rectangle, count: count)
      XCTAssertEqual(artwork.countLabel, sample["label"] as? String)
      XCTAssertEqual(Int(artwork.countFontSize), sample["fontSize"] as? Int)
      XCTAssertEqual(count == 0, sample["plus"] as? Bool)
    }
  }
  func testFullViewCommandExcludesBottomDetachedAndOtherTaskContent() throws {
    try withStore { store, root in
      store.project = root; store.workspace.root = root
      store.workspaceTabs = [.sources(owner: "a"), .subagents(owner: "a"), .sources(owner: "b")]
      let source = store.workspaceTabs[0], detached = store.workspaceTabs[1]
      store.workspaceTabPlacements[detached.id] = .detached
      store.activateWorkspaceTab(source.id)
      store.activateChatTab()
      store.newTerminalTab(in: .bottom)
      let bottom = try XCTUnwrap(store.focusedWorkspaceContentTab)
      store.toggleWorkspaceTabView()
      XCTAssertEqual(store.activeWorkspaceContentTab, source)
      XCTAssertEqual(store.workspaceTabPlacement(bottom.id), .bottom)
      XCTAssertEqual(store.workspaceTabPlacement(detached.id), .detached)
      XCTAssertEqual(store.workspaceLayoutMenu.entries.map(\.id), [source.id])
      store.destination = .settings
      let snapshot = store.workspaceTabLayoutSnapshot
      store.toggleWorkspaceTabView()
      XCTAssertEqual(store.workspaceTabLayoutSnapshot, snapshot)
      let resources = TaskWindowResources(); resources.prepare("a", store: store); defer { resources.shutdown() }
      let tabs = try XCTUnwrap(resources.tasks["a"])
      tabs.openSources(); tabs.activate(nil); tabs.newTerminal(in: .bottom)
      let taskBottom = try XCTUnwrap(tabs.focused)
      tabs.toggleFullWidth()
      XCTAssertEqual(tabs.selected(.left)?.id, source.id)
      XCTAssertEqual(tabs.placement(taskBottom.id), .bottom)
    }
  }
}
