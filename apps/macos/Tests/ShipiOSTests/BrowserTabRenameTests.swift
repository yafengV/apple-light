import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class BrowserTabRenameTests: XCTestCase {
  private struct Reference: Decodable {
    struct Save: Decodable { var oldTitle: String?; var input: String; var current: Bool; var writes: [String?] }
    struct Discard: Decodable { var customTitle: String?; var empty: Bool; var disposable: Bool }
    struct Inline: Decodable { var oldTitle: String?; var input: String; var writes: [String?] }
    struct Key: Decodable { var key: String; var composing: Bool; var writes: [String?]; var finished: Int; var prevented: Bool }
    var messages: [String:String]; var cases: [Save]; var discard: [Discard]
    var inlineCases: [Inline]; var inlineKeys: [Key]
  }
  private func reference() throws -> Reference {
    let url = try XCTUnwrap(Bundle.module.url(forResource:"browser_tab_rename_reference_720",
      withExtension:"json",subdirectory:"Fixtures"))
    return try JSONDecoder().decode(Reference.self,from:Data(contentsOf:url))
  }
  private func store() -> WorkspaceStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = WorkspaceStore(dataRoot:root)
    store.libraryLoaded = true; store.scopeLoaded = true
    store.library.tasks = [.init(id:"a",project:"",title:"A",runIDs:[]),
      .init(id:"b",project:"",title:"B",runIDs:[])]
    store.applyTaskSelection(store.library.tasks[0])
    addTeardownBlock { @MainActor in
      store.workspace.browser.shutdown()
      try? FileManager.default.removeItem(at:root)
    }
    return store
  }
  private func rename(_ session: BrowserSession, page: BrowserTab, value: String) throws {
    XCTAssertTrue(session.beginRename(page.id))
    let request = try XCTUnwrap(session.renameRequest)
    XCTAssertTrue(session.saveRename(request,title:value))
    session.endRename(request)
  }
  func testGuardedTrimmedSavesMatchActualReference() throws {
    let samples = try reference().cases
    XCTAssertEqual(samples.count,24)
    for sample in samples {
      let session = BrowserSession(); defer { session.shutdown() }
      let page = session.newTab(); page.setCustomTitle(sample.oldTitle)
      var writes: [String?] = []
      session.onTabRenamed = { _ in writes.append(page.customTitle) }
      XCTAssertTrue(session.beginRename(page.id))
      let request = try XCTUnwrap(session.renameRequest)
      if !sample.current { session.close(page.id); _ = session.newTab(id:page.id) }
      XCTAssertEqual(session.saveRename(request,title:sample.input),sample.current)
      XCTAssertEqual(writes,sample.writes)
      session.endRename(request)
    }
  }
  func testDefaultInlineValueAndPlaceholderUseDefaultPageTitle() throws {
    let session = BrowserSession(); defer { session.shutdown() }
    let page = session.newTab(); XCTAssertTrue(session.beginRename(page.id))
    let request = try XCTUnwrap(session.renameRequest)
    XCTAssertEqual(request.initialTitle,"")
    XCTAssertEqual(request.defaultTitle,"新标签页")
    session.endRename(request)
    try rename(session,page:page,value:"Custom")
    XCTAssertTrue(session.beginRename(page.id))
    XCTAssertEqual(session.renameRequest?.initialTitle,"Custom")
    XCTAssertEqual(session.renameRequest?.defaultTitle,"新标签页")
  }
  func testActualNativeBlurCallbackMatchesInlineReferenceWithoutStealingFocus() throws {
    let samples = try reference().inlineCases
    XCTAssertEqual(samples.count,12)
    for sample in samples {
      let session = BrowserSession(); defer { session.shutdown() }
      let page = session.newTab(); page.setCustomTitle(sample.oldTitle)
      XCTAssertTrue(session.beginRename(page.id))
      let request = try XCTUnwrap(session.renameRequest)
      var writes: [String?] = []; var focusRequests=0
      session.onTabRenamed = { _ in writes.append(page.customTitle) }
      let coordinator = BrowserTabTitleEditor.Coordinator(session:session,request:request,onFinish:{focusRequests += 1})
      let field=NSTextField(); field.stringValue=sample.input
      coordinator.controlTextDidEndEditing(Notification(name:NSControl.textDidEndEditingNotification,object:field))
      XCTAssertEqual(writes,sample.writes); XCTAssertEqual(focusRequests,0)
      XCTAssertNil(session.renameRequest)
      coordinator.controlTextDidEndEditing(Notification(name:NSControl.textDidEndEditingNotification,object:field))
      XCTAssertEqual(writes,sample.writes,"Late duplicate blur cannot write twice")
    }
  }
  func testActualNativeEnterEscapeAndCompositionMatchInlineReference() throws {
    for sample in try reference().inlineKeys {
      let session = BrowserSession(); defer { session.shutdown() }
      let page = session.newTab(); page.setCustomTitle("Original")
      XCTAssertTrue(session.beginRename(page.id))
      let request = try XCTUnwrap(session.renameRequest)
      var writes: [String?] = []; var focusRequests=0
      session.onTabRenamed = { _ in writes.append(page.customTitle) }
      let coordinator = BrowserTabTitleEditor.Coordinator(session:session,request:request,onFinish:{focusRequests += 1})
      let field=NSTextField(); field.stringValue=" Changed "
      let text=NSTextView(); text.string=" Changed "
      if sample.composing {
        text.setMarkedText(" Changed ",selectedRange:NSRange(location:1,length:0),replacementRange:NSRange(location:0,length:text.string.utf16.count))
        XCTAssertTrue(text.hasMarkedText())
      }
      let selector: Selector = sample.key == "Enter" ? #selector(NSResponder.insertNewline(_:))
        : sample.key == "Escape" ? #selector(NSResponder.cancelOperation(_:)) : #selector(NSResponder.insertTab(_:))
      XCTAssertEqual(coordinator.control(field,textView:text,doCommandBy:selector),sample.prevented)
      XCTAssertEqual(writes,sample.writes)
      XCTAssertEqual(focusRequests,sample.finished)
      if sample.key == "Escape" { XCTAssertEqual(page.customTitle,"Original") }
      if sample.composing || sample.key == "Tab" { XCTAssertEqual(session.renameRequest?.id,request.id) }
    }
  }
  func testCancelNoOpAndOldRequestCannotAffectNewRequest() throws {
    let session = BrowserSession(); defer { session.shutdown() }
    let page = session.newTab(); page.setCustomTitle("Original")
    XCTAssertTrue(session.beginRename(page.id))
    let old = try XCTUnwrap(session.renameRequest)
    XCTAssertFalse(session.beginRename(page.id))
    session.endRename(old)
    XCTAssertEqual(page.title,"Original")
    XCTAssertTrue(session.beginRename(page.id))
    let current = try XCTUnwrap(session.renameRequest)
    session.endRename(old)
    XCTAssertEqual(session.renameRequest?.id,current.id)
    XCTAssertFalse(session.saveRename(old,title:"stale"))
    var writes = 0; session.onTabRenamed = { _ in writes += 1 }
    XCTAssertTrue(session.saveRename(current,title:" Original \n"))
    XCTAssertEqual(writes,0)
    XCTAssertTrue(session.saveRename(current,title:" \n"))
    XCTAssertNil(page.customTitle); XCTAssertEqual(page.title,page.pageTitle)
    XCTAssertEqual(writes,1)
  }
  func testNamedEmptyPageIsRetainedInBothWindowsUntilTitleIsCleared() throws {
    for sample in try reference().discard where sample.empty {
      let store = store(); store.newBrowserTab(in:.right)
      let page = try XCTUnwrap(store.workspace.browser.selected)
      try rename(store.workspace.browser,page:page,value:sample.customTitle ?? "")
      store.executeCommand("browser")
      XCTAssertEqual(page.closed,sample.disposable)
      let resources = TaskWindowResources(); resources.prepare("a",store:store)
      defer { resources.shutdown() }
      let tabs = try XCTUnwrap(resources.tasks["a"])
      tabs.newBrowser(in:.right)
      let other = try XCTUnwrap(tabs.browser.session.selected)
      try rename(tabs.browser.session,page:other,value:sample.customTitle ?? "")
      XCTAssertTrue(tabs.perform("browser"))
      XCTAssertEqual(other.closed,sample.disposable)
      if !sample.disposable {
        store.executeCommand("browser")
        try rename(store.workspace.browser,page:page,value:" ")
        store.executeCommand("browser"); XCTAssertTrue(page.closed)
        XCTAssertTrue(tabs.perform("browser"))
        try rename(tabs.browser.session,page:other,value:"")
        XCTAssertTrue(tabs.perform("browser")); XCTAssertTrue(other.closed)
      }
    }
  }
  func testInlineRenameDoesNotChangeSelectionAddressDraftOrHideWorkspaceCommands() throws {
    let store = store(); store.newBrowserTab(in:.right)
    let page = try XCTUnwrap(store.workspace.browser.selected)
    page.setAddressDraft("unsent")
    let content = try XCTUnwrap(store.focusedWorkspaceContentTab)
    let layout = store.workspaceTabLayoutSnapshot
    XCTAssertTrue(store.beginWorkspaceBrowserRename(content.id))
    XCTAssertTrue(store.browserRenameActive)
    XCTAssertTrue(store.commandEnabled("browser"),"Inline editing does not impose a window modal")
    XCTAssertFalse(store.beginWorkspaceBrowserRename(content.id))
    let request = try XCTUnwrap(store.workspace.browser.renameRequest)
    XCTAssertTrue(store.workspace.browser.saveRename(request,title:" Docs "))
    store.workspace.browser.endRename(request)
    XCTAssertEqual(page.address,"unsent"); XCTAssertTrue(page.hasAddressInputDraft)
    var expected = layout; expected.tabs[0].browserCustomTitle = "Docs"
    XCTAssertEqual(store.workspaceTabLayoutSnapshot,expected)
    XCTAssertFalse(store.browserRenameActive)
  }
  func testWindowSessionsOwnIndependentDraftsAndRejectForeignIDs() throws {
    let store = store(); store.newBrowserTab()
    let mainPage = try XCTUnwrap(store.workspace.browser.selected)
    let resources = TaskWindowResources(); resources.prepare("a",store:store); defer { resources.shutdown() }
    let tabs = try XCTUnwrap(resources.tasks["a"]); tabs.newBrowser()
    let taskPage = try XCTUnwrap(tabs.browser.session.selected)
    XCTAssertFalse(tabs.browser.session.beginRename(mainPage.id))
    XCTAssertTrue(store.workspace.browser.beginRename(mainPage.id))
    XCTAssertTrue(tabs.browser.session.beginRename(taskPage.id))
    let mainRequest = try XCTUnwrap(store.workspace.browser.renameRequest)
    let taskRequest = try XCTUnwrap(tabs.browser.session.renameRequest)
    XCTAssertFalse(tabs.browser.session.saveRename(mainRequest,title:"foreign"))
    XCTAssertTrue(tabs.browser.session.saveRename(taskRequest,title:"Task"))
    tabs.browser.session.endRename(taskRequest)
    XCTAssertNotNil(store.workspace.browser.renameRequest)
    XCTAssertNil(mainPage.customTitle); XCTAssertEqual(taskPage.customTitle,"Task")
    store.workspace.browser.shutdown()
    XCTAssertNil(store.workspace.browser.renameRequest)
    XCTAssertFalse(store.workspace.browser.saveRename(mainRequest,title:"closed"))
  }
  func testMainColdLayoutAndClosedSidebarPinRestoreCustomTitle() async throws {
    let original = store(); original.newBrowserTab(in:.right)
    let page = try XCTUnwrap(original.workspace.browser.selected)
    let id = try XCTUnwrap(original.focusedWorkspaceContentTab?.id)
    original.pinWorkspaceTab(id)
    try rename(original.workspace.browser,page:page,value:" Named page ")
    let pin = try XCTUnwrap(original.library.pinnedContentTabs.first)
    XCTAssertEqual(pin.browserCustomTitle,"Named page"); XCTAssertEqual(pin.title,"Named page")
    XCTAssertTrue(original.saveLibrary())
    let cold = WorkspaceStore(dataRoot:original.dataRoot); defer { cold.workspace.browser.shutdown() }
    cold.library = try WorkspaceLibrary.load(from:original.dataRoot.appendingPathComponent("workspace.json"))
    cold.libraryLoaded = true; cold.scopeLoaded = true
    cold.applyTaskSelection(try XCTUnwrap(cold.library.tasks.first))
    let restored = try XCTUnwrap(cold.workspace.browser.tabs.first)
    XCTAssertEqual(restored.id,page.id); XCTAssertEqual(restored.title,"Named page")
    XCTAssertFalse(restored.canDiscardEmptyNewTab)
    cold.closeWorkspaceTab(id)
    await cold.openPinnedWorkspaceTab(pin.id)
    XCTAssertEqual(cold.workspace.browser.selected?.customTitle,"Named page")
    XCTAssertNotEqual(cold.workspace.browser.selected?.id,page.id)
    let reopened = try XCTUnwrap(cold.workspace.browser.selected)
    try rename(cold.workspace.browser,page:reopened,value:"")
    XCTAssertNil(cold.library.pinnedContentTabs.first?.browserCustomTitle)
    XCTAssertEqual(cold.library.pinnedContentTabs.first?.title,reopened.pageTitle)
  }
  func testTaskColdLayoutPinAndReopenPreserveTitle() throws {
    let original = store()
    let resources = TaskWindowResources(); resources.prepare("a",store:original,windowID:"source")
    defer { resources.shutdown() }
    let tabs = try XCTUnwrap(resources.tasks["a"]); tabs.newBrowser(in:.right)
    let page = try XCTUnwrap(tabs.browser.session.selected)
    let id = try XCTUnwrap(tabs.focusedID)
    resources.pin(id,taskID:"a")
    try rename(tabs.browser.session,page:page,value:"Window title")
    XCTAssertTrue(original.saveLibrary())
    let cold = WorkspaceStore(dataRoot:original.dataRoot)
    cold.library = try WorkspaceLibrary.load(from:original.dataRoot.appendingPathComponent("workspace.json"))
    cold.libraryLoaded = true
    let restored = TaskWindowResources(); restored.prepare("a",store:cold,windowID:"source")
    defer { restored.shutdown() }
    let result = try XCTUnwrap(restored.tasks["a"])
    XCTAssertEqual(result.browser.session.selected?.customTitle,"Window title")
    XCTAssertEqual(cold.library.pinnedContentTabs.first?.browserCustomTitle,"Window title")
    result.close(id); result.reopen()
    XCTAssertEqual(result.browser.session.selected?.customTitle,"Window title")
  }
  func testSavedTransferMetadataAndLegacyDataDoNotConfuseDefaultAndCustomTitles() throws {
    let store = store(); store.newBrowserTab(in:.right)
    let page = try XCTUnwrap(store.workspace.browser.selected)
    try rename(store.workspace.browser,page:page,value:"Transferred")
    let content = try XCTUnwrap(store.focusedWorkspaceContentTab)
    let saved = store.savedWorkspaceTab(content)
    let destination = self.store()
    XCTAssertNotNil(destination.materializeWorkspaceTab(saved,owner:"b"))
    XCTAssertEqual(destination.workspace.browser.tabs.first?.customTitle,"Transferred")
    let old = Data("""
      {"id":"browser:\(UUID())","kind":"browser","placement":"right"}
      """.utf8)
    XCTAssertNil(try JSONDecoder().decode(SavedWorkspaceTab.self,from:old).browserCustomTitle)
    let oldPin = Data("""
      {"id":"pin","sourceTabID":"browser:old","owner":"a","kind":"browser","title":"Default"}
      """.utf8)
    XCTAssertNil(try JSONDecoder().decode(PinnedWorkspaceTab.self,from:oldPin).browserCustomTitle)
  }
  func testNavigationChangesDefaultTitleButKeepsCustomTitleAndClearUsesLatestPage() async throws {
    let session = BrowserSession(); defer { session.shutdown() }
    let page = session.newTab()
    var visitedTitles: [String] = []
    session.onVisit = { _, title, _ in visitedTitles.append(title) }
    try rename(session,page:page,value:"My label")
    page.view.loadHTMLString("<title>Updated page title</title><p>local test</p>",baseURL:nil)
    for _ in 0..<200 where page.pageTitle != "Updated page title" {
      try await Task.sleep(for:.milliseconds(20))
    }
    XCTAssertEqual(page.pageTitle,"Updated page title")
    XCTAssertEqual(page.title,"My label")
    XCTAssertEqual(visitedTitles.last,"Updated page title")
    try rename(session,page:page,value:"\n")
    XCTAssertEqual(page.title,"Updated page title")
  }
  func testFullViewChatSelectionKeepsNamedPageInBothWindowsAndCloseUndoKeepsName() throws {
    let store = store(); store.newBrowserTab(in:.left)
    let page = try XCTUnwrap(store.workspace.browser.selected)
    let id = try XCTUnwrap(store.focusedWorkspaceContentTab?.id)
    try rename(store.workspace.browser,page:page,value:"Keep me")
    store.activateChatTab()
    XCTAssertFalse(page.closed); XCTAssertTrue(store.workspaceTabs.contains { $0.id == id })
    store.activateWorkspaceTab(id); store.closeWorkspaceTab(id); store.reopenClosedWorkspaceTab()
    XCTAssertEqual(store.workspace.browser.selected?.customTitle,"Keep me")
    let resources = TaskWindowResources(); resources.prepare("a",store:store); defer { resources.shutdown() }
    let tabs = try XCTUnwrap(resources.tasks["a"]); tabs.newBrowser(in:.left)
    let other = try XCTUnwrap(tabs.browser.session.selected)
    try rename(tabs.browser.session,page:other,value:"Keep task")
    tabs.activate(nil)
    XCTAssertFalse(other.closed); XCTAssertEqual(tabs.browser.session.tabs.count,1)
  }
  func testScopeChangeInvalidatesModalImmediatelyAndOtherModalsCannotBeginRename() throws {
    let store = store(); store.newBrowserTab(in:.right)
    let page = try XCTUnwrap(store.workspace.browser.selected)
    let id = try XCTUnwrap(store.focusedWorkspaceContentTab?.id)
    store.showingTaskStatus = true
    XCTAssertFalse(store.beginWorkspaceBrowserRename(id))
    store.showingTaskStatus = false
    XCTAssertTrue(store.beginWorkspaceBrowserRename(id))
    let old = try XCTUnwrap(store.workspace.browser.renameRequest)
    store.applyTaskSelection(store.library.tasks[1])
    XCTAssertNil(store.workspace.browser.renameRequest)
    XCTAssertFalse(store.workspace.browser.saveRename(old,title:"stale"))
    XCTAssertNil(page.customTitle)
    XCTAssertFalse(store.beginWorkspaceBrowserRename(id))
  }
}
