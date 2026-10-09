import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class WorkspaceLayoutMenuTests: XCTestCase {
  func testMatchesPinnedActualRoutePolicyAndHoverHandlers() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource:"workspace_layout_menu_reference_717",withExtension:"json",subdirectory:"Fixtures"))
    let data = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
    let policies = try XCTUnwrap(data["policies"] as? [[String:Any]])
    XCTAssertEqual(policies.count,18)
    for policy in policies {
      let count = try XCTUnwrap(policy["count"] as? Int)
      let menu = WorkspaceLayoutMenu(entries:(0..<count).map { .init(id:String($0),title:String($0),icon:"doc") },
        contentVisible:policy["display"] as? String != "chat",home:policy["home"] as? Bool == true)
      XCTAssertEqual(menu.kind.rawValue,policy["kind"] as? String)
    }
    for name in ["retained","empty"] {
      let trace = try XCTUnwrap(data[name] as? [String:Any])
      XCTAssertEqual(trace["afterTouch"] as? Bool,false); XCTAssertEqual(trace["afterMouse"] as? Bool,true)
      XCTAssertEqual(trace["keyboardFocus"] as? String,"last")
      let events = try XCTUnwrap(trace["events"] as? [[String:Any]])
      XCTAssertTrue(events.contains { $0["event"] as? String == "timer" && $0["ms"] as? Int == 100 })
      XCTAssertTrue(events.contains { $0["event"] as? String == (name == "retained" ? "toggle" : "create") })
    }
  }
  private func nativeFixture(_ menu: WorkspaceLayoutMenu,
    perform: @escaping (WorkspaceLayoutMenu.Action)->Void = { _ in }) -> (NSWindow,WorkspaceLayoutMenuButton.Trigger,WorkspaceLayoutMenuButton.Coordinator,NSTextView) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect:.init(x:0,y:0,width:500,height:300),styleMask:[.titled],backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false
    let editor = NSTextView(frame:.init(x:20,y:20,width:300,height:80))
    window.contentView!.addSubview(editor)
    let parent = WorkspaceLayoutMenuButton(menu:menu,shortcut:"",perform:perform)
    let owner = parent.makeCoordinator(), button = WorkspaceLayoutMenuButton.Trigger(frame:.init(x:450,y:260,width:28,height:26))
    button.owner = owner; button.target = owner
    window.contentView!.addSubview(button); owner.attach(button); window.makeFirstResponder(editor)
    return (window,button,owner,editor)
  }
  func testNativeHoverPreservesComposerFocusClickTogglesAndDismantleRejectsLateSelection() throws {
    let menu = WorkspaceLayoutMenu(entries:[.init(id:"one",title:"One",icon:"doc")],contentVisible:false,home:false)
    var actions:[WorkspaceLayoutMenu.Action] = []
    let (window,button,owner,editor) = nativeFixture(menu) { actions.append($0) }
    defer { owner.detach(); window.close() }
    owner.hover(button)
    let popup = try XCTUnwrap(owner.popup)
    XCTAssertTrue(window.firstResponder === editor); XCTAssertTrue(popup.superview === window.contentView)
    owner.click(button)
    XCTAssertEqual(actions,[.toggle]); XCTAssertNil(owner.popup)
    owner.open(button,keyboard:true,last:true)
    let last = try XCTUnwrap(window.firstResponder as? WorkspaceLayoutMenuButton.Item)
    XCTAssertEqual(last.menuAction,.select("one",.full))
    WorkspaceLayoutMenuButton.dismantleNSView(button,coordinator:owner)
    owner.select(last); owner.click(button)
    XCTAssertEqual(actions,[.toggle]); XCTAssertNil(owner.popup)
  }
  func testNativeKeyboardFocusCancelsPendingHoverClose() async throws {
    let menu = WorkspaceLayoutMenu(entries:[.init(id:"one",title:"One",icon:"doc")],contentVisible:false,home:false)
    let (window,button,owner,_) = nativeFixture(menu)
    defer { owner.detach(); window.close() }
    owner.hover(button); owner.leave(from:.init(x:460,y:260),fromPopup:false)
    XCTAssertNotNil(owner.interaction.closeDeadline)
    owner.open(button,keyboard:true,last:true)
    XCTAssertNil(owner.interaction.closeDeadline)
    try await Task.sleep(for:.milliseconds(150))
    XCTAssertNotNil(owner.popup); XCTAssertEqual(owner.interaction.origin,.keyboard)
    owner.dismiss(restore:true); XCTAssertTrue(window.firstResponder === button)
  }
  func testNativeLiveMenuRefreshPreservesFocusedActionAndRejectsRemovedTarget() throws {
    let menu = WorkspaceLayoutMenu(entries:[.init(id:"one",title:"One",icon:"doc"),.init(id:"two",title:"Two",icon:"doc")],contentVisible:false,home:false)
    var actions:[WorkspaceLayoutMenu.Action] = []
    let (window,button,owner,_) = nativeFixture(menu) { actions.append($0) }
    defer { owner.detach(); window.close() }
    owner.open(button,keyboard:true,last:true)
    let oldItem = try XCTUnwrap(window.firstResponder as? WorkspaceLayoutMenuButton.Item)
    owner.parent = .init(menu:.init(entries:[.init(id:"two",title:"Renamed",icon:"doc")],contentVisible:false,home:false),shortcut:"") { actions.append($0) }
    owner.refreshMenu()
    let renamed = try XCTUnwrap(window.firstResponder as? WorkspaceLayoutMenuButton.Item)
    XCTAssertFalse(renamed === oldItem); XCTAssertEqual(renamed.menuAction,.select("two",.full))
    XCTAssertEqual(renamed.accessibilityLabel(),"在完整视图中打开 Renamed")
    owner.parent = .init(menu:.init(entries:[.init(id:"one",title:"One",icon:"doc")],contentVisible:false,home:false),shortcut:"") { actions.append($0) }
    owner.select(renamed); XCTAssertTrue(actions.isEmpty)
  }
  func testNativeEscapeFromHoverKeepsComposerAndTabVisitsBothRowActions() throws {
    let menu = WorkspaceLayoutMenu(entries:[.init(id:"one",title:"One",icon:"doc")],contentVisible:false,home:false)
    let (window,button,owner,editor) = nativeFixture(menu)
    defer { owner.detach(); window.close() }
    func key(_ code:UInt16, flags:NSEvent.ModifierFlags = []) throws -> NSEvent {
      try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,
        windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code))
    }
    owner.hover(button)
    XCTAssertTrue(owner.handle(try key(53))); XCTAssertNil(owner.popup); XCTAssertTrue(window.firstResponder === editor)
    owner.open(button,keyboard:true)
    XCTAssertEqual((window.firstResponder as? WorkspaceLayoutMenuButton.Item)?.menuAction,.select("one",.split))
    XCTAssertFalse(owner.handle(try key(125))) // Retained rows use ordinary buttons, not menu arrow navigation.
    XCTAssertTrue(owner.handle(try key(48)))
    XCTAssertEqual((window.firstResponder as? WorkspaceLayoutMenuButton.Item)?.menuAction,.select("one",.full))
    XCTAssertTrue(owner.handle(try key(48,flags:.shift)))
    XCTAssertEqual((window.firstResponder as? WorkspaceLayoutMenuButton.Item)?.menuAction,.select("one",.split))
    XCTAssertTrue(owner.handle(try key(53))); XCTAssertTrue(window.firstResponder === button)
  }
  func testBothWindowsCreateFullAndSplitNewTabsWithoutDuplicateCreation() throws {
    for mode in [WorkspaceContentLayoutMode.full,.split] {
      var failure:Error?
      withStore { store in
        do {
          store.newTask(); store.performWorkspaceLayoutMenuAction(.create(mode))
          XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode,mode); XCTAssertEqual(store.workspacePrimaryContentTabs.count,1)
          let resources = TaskWindowResources(); resources.prepare("new:menu",store:store); defer { resources.shutdown() }
          let tabs = try XCTUnwrap(resources.tasks["new:menu"])
          tabs.performLayoutMenuAction(.create(mode))
          XCTAssertEqual(tabs.effectiveContentLayoutMode,mode); XCTAssertEqual(tabs.primaryContentTabs.count,1)
          tabs.performLayoutMenuAction(.create(mode)); XCTAssertEqual(tabs.primaryContentTabs.count,1)
        } catch { failure = error }
      }
      if let failure { throw failure }
    }
  }
  func testNativeHoverGraceClosesWithoutTakingComposerFocus() async throws {
    let menu = WorkspaceLayoutMenu(entries:[],contentVisible:false,home:true)
    let (window,button,owner,editor) = nativeFixture(menu)
    defer { owner.detach(); window.close() }
    owner.hover(button); owner.leave(from:.init(x:460,y:260),fromPopup:false)
    try await Task.sleep(for:.milliseconds(150))
    XCTAssertNil(owner.popup); XCTAssertTrue(window.firstResponder === editor)
    owner.click(button)
  }
  func testNativeTravelTrackingWorksWithoutPointerCursorPreferenceAndDetaches() throws {
    let menu = WorkspaceLayoutMenu(entries:[.init(id:"one",title:"One",icon:"doc")],contentVisible:false,home:false)
    let (window,button,owner,_) = nativeFixture(menu)
    defer { owner.detach(); window.close() }
    window.acceptsMouseMovedEvents = false
    let surface = try XCTUnwrap(window.contentView?.superview ?? window.contentView)
    XCTAssertTrue(surface.trackingAreas.contains { ($0.owner as? WorkspaceLayoutMenuButton.Coordinator) === owner && $0.options.contains(.mouseMoved) })
    owner.hover(button)
    let anchor = button.convert(button.bounds,to:nil)
    owner.leave(from:.init(x:anchor.midX,y:anchor.minY),fromPopup:false)
    func move(_ point:NSPoint) throws -> NSEvent {
      try XCTUnwrap(NSEvent.mouseEvent(with:.mouseMoved,location:point,modifierFlags:[],timestamp:1,
        windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:0,pressure:0))
    }
    owner.mouseMoved(with:try move(.init(x:anchor.midX,y:anchor.minY-4)))
    XCTAssertNotNil(owner.popup)
    owner.mouseMoved(with:try move(.init(x:0,y:anchor.minY-4)))
    XCTAssertNil(owner.popup); XCTAssertFalse(window.acceptsMouseMovedEvents)
    owner.detach()
    XCTAssertFalse(surface.trackingAreas.contains { ($0.owner as? WorkspaceLayoutMenuButton.Coordinator) === owner })
  }
  func testChooserPolicyExcludesVisibleContentAndEmptyExistingThread() {
    let entry = WorkspaceLayoutMenu.Entry(id:"one",title:"One",icon:"doc")
    for home in [true,false] {
      XCTAssertEqual(WorkspaceLayoutMenu(entries:[entry],contentVisible:true,home:home).kind,.toggle)
      XCTAssertEqual(WorkspaceLayoutMenu(entries:[entry],contentVisible:false,home:home).kind,.retained)
    }
    XCTAssertEqual(WorkspaceLayoutMenu(entries:[],contentVisible:false,home:true).actions,[.create(.split),.create(.full)])
    XCTAssertEqual(WorkspaceLayoutMenu(entries:[],contentVisible:false,home:false).kind,.toggle)
    let menu = WorkspaceLayoutMenu(entries:[entry,.init(id:"disabled",title:"Disabled",icon:"doc",enabled:false)],contentVisible:false,home:false)
    XCTAssertEqual(menu.actions,[.select("one",.split),.select("one",.full)])
    XCTAssertFalse(menu.accepts(.select("disabled",.full)))
    XCTAssertFalse(menu.accepts(.create(.split)))
  }
  func testHoverGraceAndKeyboardOwnership() {
    let menu = WorkspaceLayoutMenu(entries:[.init(id:"one",title:"One",icon:"doc")],contentVisible:false,home:false)
    var state = WorkspaceLayoutMenuInteraction()
    state.open(.hover); state.leave(now:10)
    XCTAssertFalse(state.expired(now:10.099)); XCTAssertTrue(state.expired(now:10.101))
    state.enter(); XCTAssertNil(state.closeDeadline)
    state.keyboard(menu,last:true)
    XCTAssertEqual(state.highlighted,.select("one",.full))
    state.leave(now:11); XCTAssertNil(state.closeDeadline)
    state.dismiss(); XCTAssertNil(state.origin); XCTAssertNil(state.highlighted)
  }
  func testToolbarPlacementAllowsAnchorAboveContentAndClampsNarrowWindow() throws {
    let viewport = NSRect(x:0,y:0,width:500,height:300)
    let placement = try XCTUnwrap(WorkspaceLayoutMenuButton.placement(anchor:.init(x:470,y:310,width:28,height:26),viewport:viewport,height:200))
    XCTAssertTrue(viewport.contains(placement)); XCTAssertEqual(placement.maxX,494)
    XCTAssertNil(WorkspaceLayoutMenuButton.placement(anchor:.init(x:550,y:310,width:28,height:26),viewport:viewport,height:200))
    XCTAssertNil(WorkspaceLayoutMenuButton.placement(anchor:.zero,viewport:.zero,height:80))
    let narrow = try XCTUnwrap(WorkspaceLayoutMenuButton.placement(anchor:.init(x:70,y:110,width:28,height:26),viewport:.init(x:0,y:0,width:100,height:100),height:400))
    XCTAssertEqual(narrow.width,88); XCTAssertEqual(narrow.height,88)
  }
  func testPointerCorridorKeepsDiagonalTravelAndRejectsOutsideOrDegenerateTriangle() {
    let destination = NSRect(x:0,y:0,width:200,height:100), source = NSPoint(x:180,y:130)
    XCTAssertTrue(WorkspaceLayoutMenuButton.inCorridor(.init(x:170,y:115),from:source,to:destination))
    XCTAssertFalse(WorkspaceLayoutMenuButton.inCorridor(.init(x:220,y:115),from:source,to:destination))
    XCTAssertFalse(WorkspaceLayoutMenuButton.inCorridor(.init(x:170,y:145),from:source,to:destination))
    XCTAssertFalse(WorkspaceLayoutMenuButton.inCorridor(.init(x:170,y:100),from:.init(x:180,y:100),to:destination))
  }
  private func withStore(_ body:(WorkspaceStore)->Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let store = WorkspaceStore(dataRoot:root); defer { store.workspace.browser.shutdown() }
    store.libraryLoaded = true; store.scopeLoaded = true
    store.library.tasks = ["a","b"].map { .init(id:$0,project:"",title:$0,runIDs:[]) }
    store.applyTaskSelection(store.library.tasks[0]); body(store)
  }
  func testMainChooserSelectsExactRetainedTabInBothLayoutsAndRejectsStaleOwner() {
    withStore { store in
      store.workspaceTabs = [.sources(owner:"a"),.subagents(owner:"a"),.sources(owner:"b")]
      store.activateWorkspaceTab(store.workspaceTabs[0].id)
      store.activateChatTab(); store.showingInspector = false
      XCTAssertEqual(store.workspaceLayoutMenu.entries.map(\.id),Array(store.workspaceTabs.prefix(2)).map(\.id))
      let id = store.workspaceTabs[1].id
      store.performWorkspaceLayoutMenuAction(.select(id,.split))
      XCTAssertEqual(store.focusedWorkspaceContentTab?.id,id); XCTAssertTrue(store.showsWorkspaceInspector)
      store.toggleWorkspaceContentVisibility()
      store.performWorkspaceLayoutMenuAction(.select(id,.full))
      XCTAssertEqual(store.activeWorkspaceContentTab?.id,id); XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode,.full)
      store.applyTaskSelection(store.library.tasks[1])
      let snapshot = store.workspaceTabLayoutSnapshot
      store.performWorkspaceLayoutMenuAction(.select(id,.full))
      XCTAssertEqual(store.workspaceTabLayoutSnapshot,snapshot)
    }
  }
  func testTaskChooserExcludesBottomAndRejectsRemovedTarget() throws {
    var failure: Error?
    withStore { store in
      do {
        let resources = TaskWindowResources(); resources.prepare("a",store:store); defer { resources.shutdown() }
        let tabs = try XCTUnwrap(resources.tasks["a"])
        tabs.openSources(); tabs.openSubagents(); tabs.newTerminal(in:.bottom)
        tabs.activate(nil); tabs.showingRight = false
        XCTAssertEqual(tabs.layoutMenu.entries.count,2)
        let id = tabs.primaryContentTabs[1].id
        tabs.performLayoutMenuAction(.select(id,.split))
        XCTAssertEqual(tabs.focusedID,id); XCTAssertTrue(tabs.showsContentSidePanel)
        tabs.toggleContentVisibility(); tabs.performLayoutMenuAction(.select(id,.full))
        XCTAssertEqual(tabs.selected(.left)?.id,id)
        tabs.close(id); let snapshot = tabs.layoutSnapshot
        tabs.performLayoutMenuAction(.select(id,.full)); XCTAssertEqual(tabs.layoutSnapshot,snapshot)
      } catch { failure = error }
    }
    if let failure { throw failure }
  }
  func testEmptyHomeCreatesRequestedLayoutOnceAndExistingThreadDoesNotExposeCreate() {
    withStore { store in
      XCTAssertEqual(store.workspaceLayoutMenu.kind,.toggle)
      store.performWorkspaceLayoutMenuAction(.create(.full)); XCTAssertTrue(store.workspaceTabs.isEmpty)
      store.newTask()
      XCTAssertEqual(store.workspaceLayoutMenu.kind,.newTab)
      store.performWorkspaceLayoutMenuAction(.create(.split))
      XCTAssertEqual(store.workspacePrimaryContentTabs.count,1); XCTAssertTrue(store.showsWorkspaceInspector)
      store.performWorkspaceLayoutMenuAction(.create(.full)); XCTAssertEqual(store.workspacePrimaryContentTabs.count,1)
    }
  }
}
