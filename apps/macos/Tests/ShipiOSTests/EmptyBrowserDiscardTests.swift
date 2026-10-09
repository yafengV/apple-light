import XCTest
@testable import ShipiOS

@MainActor final class EmptyBrowserDiscardTests: XCTestCase {
  private struct Reference: Decodable {
    struct Case: Decodable {
      struct Closed: Decodable { var recordCloseUndo: Bool }
      var name: String; var disposable: Bool; var discarded: Bool; var closed: [Closed]
    }
    var cases: [Case]
  }
  private func reference() throws -> Reference {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "empty_browser_discard_reference_714", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
  }
  private func withStore(_ body: (WorkspaceStore) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    defer { store.workspace.browser.shutdown() }
    store.libraryLoaded = true; store.scopeLoaded = true
    store.library.tasks = ["a", "b"].map { .init(id:$0, project:"", title:$0, runIDs:[]) }
    store.applyTaskSelection(store.library.tasks[0])
    try body(store)
  }
  func testReferenceDiscardsOnlyEmptyAndNeverRecordsCloseUndo() throws {
    let cases = try reference().cases
    XCTAssertEqual(cases.count, 17)
    for sample in cases {
      XCTAssertEqual(sample.discarded, sample.name == "empty", sample.name)
      XCTAssertTrue(sample.closed.allSatisfy { !$0.recordCloseUndo })
    }
  }
  func testMainHideDiscardsUniqueEmptyPageWithoutPollutingEitherCloseHistory() throws {
    try withStore { store in
      store.newBrowserTab(in: .right)
      let page = try XCTUnwrap(store.workspace.browser.selected)
      let id = try XCTUnwrap(store.activeRightWorkspaceContentTab?.id)
      store.executeCommand("browser")
      XCTAssertTrue(page.closed)
      XCTAssertFalse(store.workspaceTabs.contains { $0.id == id })
      XCTAssertFalse(store.workspace.browser.canReopenClosedTab)
      XCTAssertFalse(store.canReopenClosedWorkspaceTab)
      XCTAssertFalse(store.showsWorkspaceInspector)
      XCTAssertNil(store.focusedWorkspaceContentTab)
      XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode, .split)
      store.executeCommand("browser")
      XCTAssertEqual(store.workspace.browser.tabs.count, 1)
      XCTAssertNotEqual(store.workspace.browser.selected?.id, page.id)
    }
  }
  func testBothWindowHideResultsMatchSupportedReferenceCases() throws {
    let supported = Set(["empty", "address-draft", "cleared-address-draft", "pinned", "multiple", "zoom", "agent"])
    for sample in try reference().cases where supported.contains(sample.name) {
      try withStore { store in
        store.newBrowserTab(in:.right)
        let page = try XCTUnwrap(store.workspace.browser.selected)
        switch sample.name {
        case "address-draft": page.setAddressDraft("input")
        case "cleared-address-draft": page.setAddressDraft("")
        case "pinned": store.pinWorkspaceTab(try XCTUnwrap(store.activeRightWorkspaceContentTab?.id))
        case "multiple": store.newBrowserTab(in:.right)
        case "zoom": page.view.pageZoom = 1.5
        case "agent": page.agentOperationActive = true
        default: break
        }
        store.executeCommand("browser")
        XCTAssertEqual(page.closed, sample.discarded, "main: \(sample.name)")
        XCTAssertFalse(store.canReopenClosedWorkspaceTab, sample.name)
        XCTAssertFalse(store.workspace.browser.canReopenClosedTab, sample.name)

        let resources = TaskWindowResources(); resources.prepare("a", store:store); defer { resources.shutdown() }
        let tabs = try XCTUnwrap(resources.tasks["a"])
        tabs.newBrowser(in:.right)
        let taskPage = try XCTUnwrap(tabs.browser.session.selected)
        switch sample.name {
        case "address-draft": taskPage.setAddressDraft("input")
        case "cleared-address-draft": taskPage.setAddressDraft("")
        case "pinned": resources.pin(try XCTUnwrap(tabs.focusedID), taskID:"a")
        case "multiple": tabs.newBrowser(in:.right)
        case "zoom": taskPage.view.pageZoom = 1.5
        case "agent": taskPage.agentOperationActive = true
        default: break
        }
        XCTAssertTrue(tabs.perform("browser"))
        XCTAssertEqual(taskPage.closed, sample.discarded, "task: \(sample.name)")
        XCTAssertFalse(tabs.canReopen, sample.name)
        XCTAssertFalse(tabs.browser.session.canReopenClosedTab, sample.name)
      }
    }
  }
  func testTaskHideDiscardsUniqueEmptyPageAndPreservesEarlierUserCloseUndo() throws {
    try withStore { store in
      let resources = TaskWindowResources(); resources.prepare("a", store:store); defer { resources.shutdown() }
      let tabs = try XCTUnwrap(resources.tasks["a"])
      tabs.newBrowser(in:.right)
      let prior = try XCTUnwrap(tabs.focusedID)
      tabs.browser.session.selected?.address = "previous address draft"
      tabs.close(prior)
      tabs.newBrowser(in:.right)
      let discarded = try XCTUnwrap(tabs.browser.session.selected)
      XCTAssertTrue(tabs.perform("browser"))
      XCTAssertTrue(discarded.closed)
      XCTAssertTrue(tabs.tabs.isEmpty)
      tabs.reopen()
      XCTAssertEqual(tabs.browser.session.selected?.address, "previous address draft")
      XCTAssertNotEqual(tabs.browser.session.selected?.id, discarded.id)
    }
  }
  func testNativeAddressChangeThenClearRetainsEmptyDraftUntilExplicitCancel() throws {
    try withStore { store in
      store.newBrowserTab(in:.right)
      let page = try XCTUnwrap(store.workspace.browser.selected)
      let field = NSTextField()
      let coordinator = BrowserAddressField(tab:page, session:store.workspace.browser, canFocus:{false}).makeCoordinator()
      for text in ["input", ""] {
        field.stringValue = text
        coordinator.controlTextDidChange(.init(name:NSControl.textDidChangeNotification, object:field))
      }
      store.executeCommand("browser")
      XCTAssertFalse(page.closed, "A present empty address draft differs from a pristine page")
      XCTAssertEqual(store.workspace.browser.tabs.count, 1)
      store.executeCommand("browser")
      page.restoreAddress()
      store.executeCommand("browser")
      XCTAssertTrue(page.closed)
    }
  }
  func testPinnedEmptyTabsAndMultiplePrimaryTabsAreRetainedInBothWindows() throws {
    try withStore { store in
      store.newBrowserTab(in:.right)
      let id = try XCTUnwrap(store.activeRightWorkspaceContentTab?.id)
      store.pinWorkspaceTab(id)
      store.executeCommand("browser")
      XCTAssertEqual(store.workspacePrimaryContentTabs.count, 1)
      XCTAssertEqual(store.library.pinnedContentTabs.count, 1)
      let resources = TaskWindowResources(); resources.prepare("a", store:store); defer { resources.shutdown() }
      let tabs = try XCTUnwrap(resources.tasks["a"])
      tabs.newBrowser(in:.right)
      let taskID = try XCTUnwrap(tabs.focusedID)
      resources.pin(taskID, taskID:"a")
      XCTAssertTrue(tabs.perform("browser"))
      XCTAssertEqual(tabs.primaryContentTabs.count, 1)
      XCTAssertEqual(store.library.pinnedContentTabs.count, 2)
      store.newBrowserTab(in:.right)
      store.executeCommand("browser")
      XCTAssertEqual(store.workspacePrimaryContentTabs.count, 2)
    }
  }
  func testDiscardRemovesOnlyCurrentOwnersPageAndNormalCloseStillReopens() throws {
    try withStore { store in
      store.newBrowserTab(in:.right)
      let prior = try XCTUnwrap(store.activeRightWorkspaceContentTab?.id)
      store.workspace.browser.selected?.address = "prior"
      store.closeWorkspaceTab(prior)
      store.applyTaskSelection(store.library.tasks[1]); store.newBrowserTab(in:.right)
      let other = try XCTUnwrap(store.workspace.browser.selected)
      store.applyTaskSelection(store.library.tasks[0]); store.newBrowserTab(in:.right)
      let empty = try XCTUnwrap(store.workspace.browser.selected)
      store.executeCommand("browser")
      XCTAssertTrue(empty.closed)
      XCTAssertFalse(other.closed)
      store.executeCommand("browser-reopen")
      XCTAssertEqual(store.workspace.browser.selected?.address, "prior")
      XCTAssertFalse(store.workspace.browser.canReopenClosedTab(empty.id))
    }
  }

  func testEmptyAddressDraftSurvivesBothWindowLayoutRoundTrips() throws {
    try withStore { store in
      store.newBrowserTab(in:.right)
      let page = try XCTUnwrap(store.workspace.browser.selected)
      page.setAddressDraft("input"); page.setAddressDraft("")
      let saved = try JSONDecoder().decode(WorkspaceTabLayout.self, from:JSONEncoder().encode(store.workspaceTabLayoutSnapshot))
      let cold = WorkspaceStore(dataRoot:store.dataRoot.appendingPathComponent("cold"))
      defer { cold.workspace.browser.shutdown() }
      cold.libraryLoaded = true; cold.scopeLoaded = true; cold.library.tasks = store.library.tasks
      cold.selection = store.selection; cold.library.workspaceTabLayouts["a"] = saved
      cold.restoreWorkspaceTabLayout()
      let restored = try XCTUnwrap(cold.workspace.browser.selected)
      cold.executeCommand("browser")
      XCTAssertFalse(restored.closed)
      XCTAssertTrue(restored.hasAddressInputDraft)
      XCTAssertEqual(restored.address, "")
      let resources = TaskWindowResources(); resources.prepare("a", store:store); defer { resources.shutdown() }
      let tabs = try XCTUnwrap(resources.tasks["a"])
      tabs.newBrowser(in:.right); tabs.browser.session.selected?.setAddressDraft("")
      let taskSaved = try JSONDecoder().decode(TaskWindowTabLayout.self, from:JSONEncoder().encode(tabs.layoutSnapshot))
      let otherResources = TaskWindowResources(); otherResources.prepare("a", store:cold); defer { otherResources.shutdown() }
      let other = try XCTUnwrap(otherResources.tasks["a"]); other.restoreLayout(taskSaved)
      let taskPage = try XCTUnwrap(other.browser.session.selected)
      XCTAssertTrue(other.perform("browser"))
      XCTAssertFalse(taskPage.closed)
      XCTAssertTrue(taskPage.hasAddressInputDraft)
      XCTAssertEqual(taskPage.address, "")
    }
  }

  func testLegacyLayoutDraftPresenceUsesTextAndPristinePagesRemainDisposable() throws {
    try withStore { store in
      for address in ["", "legacy draft"] {
        store.newBrowserTab(in:.right)
        let page = try XCTUnwrap(store.workspace.browser.selected)
        page.address = address
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(store.workspaceTabLayoutSnapshot)) as? [String:Any])
        var entries = try XCTUnwrap(object["tabs"] as? [[String:Any]])
        for i in entries.indices { entries[i].removeValue(forKey:"addressInputDraftPresent") }
        object["tabs"] = entries
        let saved = try JSONDecoder().decode(WorkspaceTabLayout.self, from:JSONSerialization.data(withJSONObject:object))
        let cold = WorkspaceStore(dataRoot:store.dataRoot.appendingPathComponent(UUID().uuidString))
        defer { cold.workspace.browser.shutdown() }
        cold.libraryLoaded = true; cold.scopeLoaded = true; cold.library.tasks = store.library.tasks
        cold.selection = store.selection; cold.library.workspaceTabLayouts["a"] = saved
        cold.restoreWorkspaceTabLayout()
        let restored = try XCTUnwrap(cold.workspace.browser.selected)
        cold.executeCommand("browser")
        XCTAssertEqual(restored.closed, address.isEmpty)
        store.closeWorkspaceTab(try XCTUnwrap(store.activeRightWorkspaceContentTab?.id))
      }
    }
  }

  func testExistingAddressWritersSaveDraftPresenceInBothWindowLayouts() throws {
    try withStore { store in
      store.newBrowserTab(in:.right)
      let page = try XCTUnwrap(store.workspace.browser.selected)
      page.address = "existing input"
      XCTAssertEqual(store.workspaceTabLayoutSnapshot.tabs.first?.addressInputDraftPresent, true)
      let resources = TaskWindowResources(); resources.prepare("a", store:store); defer { resources.shutdown() }
      let tabs = try XCTUnwrap(resources.tasks["a"])
      tabs.newBrowser(in:.right)
      tabs.browser.session.selected?.address = "existing task input"
      let saved = tabs.layoutSnapshot
      XCTAssertEqual(saved.content.tabs.first?.addressInputDraftPresent, true)
      resources.prepare("b", store:store)
      let other = try XCTUnwrap(resources.tasks["b"])
      other.restoreLayout(saved)
      XCTAssertEqual(other.browser.session.selected?.address, "existing task input")
      XCTAssertTrue(other.browser.session.selected?.hasAddressInputDraft == true)
    }
  }

  func testZoomAndActiveAgentStatesPreventDiscardAndInactiveAddressDelegateCannotCreateDraft() throws {
    try withStore { store in
      for state in ["zoom", "agent"] {
        store.newBrowserTab(in:.right)
        let page = try XCTUnwrap(store.workspace.browser.selected)
        if state == "zoom" { page.view.pageZoom = 1.5 } else { page.agentOperationActive = true }
        store.executeCommand("browser")
        XCTAssertFalse(page.closed, state)
        store.executeCommand("browser")
        page.view.pageZoom = 1; page.agentOperationActive = false
        store.executeCommand("browser")
        XCTAssertTrue(page.closed, state)
      }
      store.newBrowserTab(in:.right)
      let page = try XCTUnwrap(store.workspace.browser.selected)
      let field = NSTextField(); field.stringValue = "late"
      let coordinator = BrowserAddressField(tab:page, session:store.workspace.browser, canFocus:{false}).makeCoordinator()
      coordinator.active = false
      coordinator.controlTextDidChange(.init(name:NSControl.textDidChangeNotification, object:field))
      XCTAssertFalse(page.hasAddressInputDraft)
      XCTAssertEqual(page.address, "")
      store.executeCommand("browser")
      XCTAssertTrue(page.closed)
    }
  }
}
