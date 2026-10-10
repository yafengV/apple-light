import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class PinnedBrowserRenameTests: XCTestCase {
  private struct Fixture {
    let store: WorkspaceStore; let session: BrowserSession; let page: BrowserTab
    let pin: PinnedWorkspaceTab; let resources: TaskWindowResources?
  }
  private struct Saves: Decodable {
    struct Case: Decodable { let oldTitle: String?; let input: String; let current: Bool; let writes: [String?] }
    var messages: [String:String]; var cases: [Case]
  }
  private struct Sources: Decodable {
    struct Case: Decodable { let name: String; let menuAvailable: Bool; let captured: Bool; let current: Bool }
    let sourceSHA256: String
    let cases: [Case]
  }
  private func reference() throws -> Saves {
    let url = try XCTUnwrap(Bundle.module.url(forResource:"browser_tab_rename_reference_720",withExtension:"json",subdirectory:"Fixtures"))
    return try JSONDecoder().decode(Saves.self,from:Data(contentsOf:url))
  }
  private func fixture(taskWindow: Bool = false) throws -> Fixture {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pin-rename-\(UUID())")
    let store = WorkspaceStore(dataRoot:root)
    store.libraryLoaded=true; store.scopeLoaded=true
    store.modelConfiguration.model=""; store.modelConfiguration.baseURL=""
    store.library.tasks=[.init(id:"a",project:"",title:"A",runIDs:[]),.init(id:"b",project:"",title:"B",runIDs:[])]
    store.library.drafts=["a":"Source draft","b":"中文主窗口草稿"]
    store.applyTaskSelection(store.library.tasks[0])
    let resources: TaskWindowResources?,session: BrowserSession,id: String
    if taskWindow {
      let source=TaskWindowResources(); source.prepare("a",store:store,windowID:"source-window")
      let tabs=try XCTUnwrap(source.tasks["a"]); tabs.newBrowser(in:.right)
      session=tabs.browser.session; id=try XCTUnwrap(tabs.focusedID); resources=source
    } else {
      store.newBrowserTab(in:.right); session=store.workspace.browser
      id=try XCTUnwrap(store.focusedWorkspaceContentTab?.id); resources=nil
    }
    let page=try XCTUnwrap(session.selected); page.setCustomTitle("Original")
    if let resources { resources.pin(id,taskID:"a") } else { store.pinWorkspaceTab(id) }
    let pin=try XCTUnwrap(store.library.pinnedContentTabs.first)
    store.applyTaskSelection(store.library.tasks[1])
    addTeardownBlock { @MainActor in
      store.cancelPinnedBrowserRename(); resources?.shutdown(); store.workspace.browser.shutdown()
      try? FileManager.default.removeItem(at:root)
    }
    return Fixture(store:store,session:session,page:page,pin:pin,resources:resources)
  }
  func testDialogMessagesBlankInitialValueAndDefaultTitleMatchReference() throws {
    let f=try fixture(); XCTAssertTrue(f.session.renameTab(f.page,title:nil))
    XCTAssertTrue(f.store.beginPinnedBrowserRename(f.pin.id))
    let request=try XCTUnwrap(f.store.pinnedBrowserRenameRequest)
    XCTAssertEqual(request.initialTitle,""); XCTAssertEqual(request.defaultTitle,f.page.pageTitle)
    let config=TaskRenameDialog.Configuration.browser(defaultTitle:request.defaultTitle)
    let messages=try reference().messages
    XCTAssertEqual(config.title,messages["Title"]); XCTAssertEqual(config.subtitle,messages["Subtitle"])
    XCTAssertEqual(config.ariaLabel,messages["AriaLabel"]); XCTAssertEqual(config.placeholder,request.defaultTitle)
    XCTAssertTrue(config.allowsEmpty); XCTAssertFalse(TaskRenameDialog.Configuration.task.allowsEmpty)
  }
  func testSidebarSavesMatchAllReferenceCasesAndRejectSameIDReplacement() throws {
    let cases=try reference().cases; XCTAssertEqual(cases.count,24)
    for sample in cases {
      let f=try fixture(); _ = f.session.renameTab(f.page,title:sample.oldTitle)
      let saved=f.store.savedWorkspaceTab(try XCTUnwrap(f.store.workspaceTabs.first { $0.browserID == f.page.id }))
      XCTAssertTrue(f.store.beginPinnedBrowserRename(f.pin.id))
      let request=try XCTUnwrap(f.store.pinnedBrowserRenameRequest)
      var writes:[String?]=[]
      let original=f.session.onTabRenamed
      f.session.onTabRenamed={ id in writes.append(f.page.customTitle); original?(id) }
      if !sample.current {
        f.store.closeWorkspaceTab(f.pin.sourceTabID)
        XCTAssertNotNil(f.store.materializeWorkspaceTab(saved,owner:"a"))
        let replacement=try XCTUnwrap(f.session.tabs.first { $0.id == f.page.id })
        XCTAssertFalse(replacement === f.page)
      }
      XCTAssertEqual(f.store.savePinnedBrowserRename(request,title:sample.input),sample.current)
      XCTAssertEqual(writes,sample.writes)
      f.store.closePinnedBrowserRename(request)
    }
  }
  func testBothSourceWindowsRenameWithoutSwitchingMainOrChangingDraftAndPersist() throws {
    for taskWindow in [false,true] {
      let f=try fixture(taskWindow:taskWindow)
      let layout=f.store.workspaceTabLayoutSnapshot,selected=f.store.selection,drafts=f.store.library.drafts
      XCTAssertTrue(f.store.canRenamePinnedBrowser(f.pin.id))
      XCTAssertTrue(f.store.beginPinnedBrowserRename(f.pin.id))
      let request=try XCTUnwrap(f.store.pinnedBrowserRenameRequest)
      XCTAssertTrue(f.store.savePinnedBrowserRename(request,title:" 新标签名 \n"))
      XCTAssertEqual(f.page.customTitle,"新标签名")
      XCTAssertEqual(f.store.selection,selected); XCTAssertEqual(f.store.library.drafts,drafts)
      XCTAssertEqual(f.store.workspaceTabLayoutSnapshot,layout)
      XCTAssertEqual(f.store.library.pinnedContentTabs.first?.title,"新标签名")
      let cold=try WorkspaceLibrary.load(from:f.store.dataRoot.appendingPathComponent("workspace.json"))
      XCTAssertEqual(cold.pinnedContentTabs.first?.browserCustomTitle,"新标签名")
      XCTAssertEqual(cold.pinnedContentTabs.first?.sourceWindowID,taskWindow ? "source-window" : nil)
      f.store.closePinnedBrowserRename(request)
      XCTAssertEqual(f.store.pinnedBrowserRenameReturnPinID,f.pin.id)
    }
  }
  func testMainModalBlocksBackgroundCommandsButInlineRenameIsNotAModal() throws {
    let f=try fixture(taskWindow:true)
    XCTAssertTrue(f.store.beginPinnedBrowserRename(f.pin.id)); XCTAssertTrue(f.store.mainRenameDialogActive)
    for command in ["new","rename","pin","send","settings","model","browser","tab-close"] {
      XCTAssertFalse(f.store.commandEnabled(command),command)
    }
    XCTAssertFalse(f.store.mainMCPApprovalVisible)
    XCTAssertFalse(f.store.canArchiveTask("b"))
    XCTAssertNil(f.store.taskNavigationShortcutContext)
    XCTAssertFalse(f.store.handleWorkspaceShortcut(ShortcutBinding("⌘W")))
    XCTAssertFalse(f.store.handleWorkspaceShortcut(ShortcutBinding("⌘N")))
    f.store.beginRenamingTask("b"); XCTAssertNil(f.store.renameTaskID)
    f.store.beginRenamingProject("blocked"); XCTAssertNil(f.store.renameProjectPath)
    f.store.cancelPinnedBrowserRename()
    XCTAssertTrue(f.session.beginRename(f.page.id)); XCTAssertFalse(f.store.mainRenameDialogActive)
    f.session.cancelRename()
  }

  func testSourceResolutionMatchesReferenceWithoutRevealingOrRestoringSources() throws {
    let url=try XCTUnwrap(Bundle.module.url(forResource:"pinned_browser_rename_reference_721",withExtension:"json",subdirectory:"Fixtures"))
    let reference=try JSONDecoder().decode(Sources.self,from:Data(contentsOf:url))
    XCTAssertEqual(reference.sourceSHA256,"22f3ea455585cfc0508e3d3627eac161c80c849c0aace3d76d09fdebaa0aeca3")
    XCTAssertEqual(reference.cases.count,18)
    for name in ["live","missing-reference","cold-scope","unpinned","missing-tab","kind-mismatch"] {
      let f=try fixture(taskWindow:name == "cold-scope")
      let sample=try XCTUnwrap(reference.cases.first { $0.name == name })
      switch name {
      case "missing-reference", "unpinned": f.store.unpinWorkspaceTab(f.pin.id)
      case "cold-scope": XCTAssertTrue(f.resources?.shutdown() == true)
      case "missing-tab": f.session.close(f.page.id)
      case "kind-mismatch": f.store.library.pinnedContentTabs[0].kind = .file
      default: break
      }
      let selection=f.store.selection,layout=f.store.workspaceTabLayoutSnapshot,drafts=f.store.library.drafts
      let count=f.store.workspace.browser.tabs.count
      XCTAssertEqual(f.store.canRenamePinnedBrowser(f.pin.id),sample.menuAvailable,name)
      XCTAssertEqual(f.store.beginPinnedBrowserRename(f.pin.id),sample.captured,name)
      XCTAssertEqual(f.store.pinnedBrowserRenameRequest != nil,sample.current,name)
      XCTAssertEqual(f.store.selection,selection); XCTAssertEqual(f.store.library.drafts,drafts)
      XCTAssertEqual(f.store.workspaceTabLayoutSnapshot,layout)
      XCTAssertEqual(f.store.workspace.browser.tabs.count,count)
    }
  }

  func testBackgroundSourcePersistsCustomTitleAndExplicitEmptyAddressDraftAcrossColdRestore() throws {
    let f=try fixture()
    f.page.setAddressDraft("")
    XCTAssertTrue(f.session.renameTab(f.page,title:"Background title"))
    XCTAssertTrue(f.store.saveLibrary())
    let disk=try WorkspaceLibrary.load(from:f.store.dataRoot.appendingPathComponent("workspace.json"))
    let saved=try XCTUnwrap(disk.workspaceTabLayouts["a"]?.tabs.first { $0.id == f.pin.sourceTabID })
    XCTAssertEqual(saved.browserCustomTitle,"Background title")
    XCTAssertEqual(saved.addressInputDraftPresent,true)
    let cold=WorkspaceStore(dataRoot:f.store.dataRoot); defer { cold.workspace.browser.shutdown() }
    cold.library=disk; cold.libraryLoaded=true; cold.scopeLoaded=true
    XCTAssertNotNil(cold.materializeWorkspaceTab(saved,owner:"a"))
    let page=try XCTUnwrap(cold.workspace.browser.tabs.first { $0.id == f.page.id })
    XCTAssertEqual(page.customTitle,"Background title")
    XCTAssertTrue(page.hasAddressInputDraft); XCTAssertTrue(page.editingAddress)
    XCTAssertFalse(page.canDiscardEmptyNewTab)
    XCTAssertEqual(cold.library.pinnedContentTabs.first?.browserCustomTitle,"Background title")
  }
  func testUnchangedDraftDoesNotOverwriteOtherWindowRenameAndOldCloseCannotDismissNewDialog() throws {
    let f=try fixture(taskWindow:true)
    XCTAssertTrue(f.store.beginPinnedBrowserRename(f.pin.id))
    let old=try XCTUnwrap(f.store.pinnedBrowserRenameRequest)
    XCTAssertTrue(f.session.renameTab(f.page,title:"Other window"))
    XCTAssertTrue(f.store.savePinnedBrowserRename(old,title:" Original \n"))
    XCTAssertEqual(f.page.customTitle,"Other window")
    f.store.closePinnedBrowserRename(old)
    XCTAssertTrue(f.store.beginPinnedBrowserRename(f.pin.id))
    let next=try XCTUnwrap(f.store.pinnedBrowserRenameRequest)
    let focus=f.store.pinnedBrowserRenameReturnFocus
    f.store.closePinnedBrowserRename(old)
    XCTAssertEqual(f.store.pinnedBrowserRenameRequest?.id,next.id)
    XCTAssertEqual(f.store.pinnedBrowserRenameReturnFocus,focus)
    XCTAssertFalse(f.store.savePinnedBrowserRename(old,title:"Stale"))
    XCTAssertTrue(f.store.savePinnedBrowserRename(next,title:"\n"))
    XCTAssertNil(f.page.customTitle); XCTAssertNil(f.store.library.pinnedContentTabs.first?.browserCustomTitle)
  }
  func testUnpinDeletedOwnerDetachedSourceDragAndProjectChangeInvalidateExactRequest() throws {
    for mutation in ["unpin","owner","window","kind","delete-owner","detached","drag","project","shutdown"] {
      let f=try fixture(taskWindow:mutation == "drag" || mutation == "shutdown")
      XCTAssertTrue(f.store.beginPinnedBrowserRename(f.pin.id))
      let request=try XCTUnwrap(f.store.pinnedBrowserRenameRequest)
      switch mutation {
      case "unpin": f.store.unpinWorkspaceTab(f.pin.id)
      case "owner": f.store.library.pinnedContentTabs[0].owner="b"
      case "window": f.store.library.pinnedContentTabs[0].sourceWindowID="other"
      case "kind": f.store.library.pinnedContentTabs[0].kind = .file
      case "delete-owner": f.store.library.tasks.removeAll { $0.id == "a" }
      case "detached":
        f.store.applyTaskSelection(try XCTUnwrap(f.store.library.tasks.first { $0.id == "a" }))
        f.store.moveWorkspaceTab(f.pin.sourceTabID,to:.detached)
        XCTAssertEqual(f.store.workspaceTabPlacement(f.pin.sourceTabID),.detached)
      case "drag": f.resources?.tasks["a"]?.beginDrag(f.pin.sourceTabID)
      case "project": f.store.library.tasks[0].project=f.store.dataRoot.path
      case "shutdown": f.resources?.shutdown()
      default: XCTFail(mutation)
      }
      XCTAssertFalse(f.store.savePinnedBrowserRename(request,title:"Invalid"),mutation)
      XCTAssertNotEqual(f.page.customTitle,"Invalid",mutation)
      f.store.cancelPinnedBrowserRename()
    }
  }
  func testColdSourceHasNoRenameActionUntilExplicitOpenRestoresIt() async throws {
    for taskWindow in [false,true] {
      let f=try fixture(taskWindow:taskWindow); XCTAssertTrue(f.store.saveLibrary())
      let cold=WorkspaceStore(dataRoot:f.store.dataRoot); defer { cold.workspace.browser.shutdown() }
      cold.library=try WorkspaceLibrary.load(from:f.store.dataRoot.appendingPathComponent("workspace.json"))
      cold.libraryLoaded=true; cold.scopeLoaded=true
      cold.modelConfiguration.model=""; cold.modelConfiguration.baseURL=""
      cold.applyTaskSelection(try XCTUnwrap(cold.library.tasks.first { $0.id == "b" }))
      let drafts=cold.library.drafts,selection=cold.selection
      XCTAssertFalse(cold.canRenamePinnedBrowser(f.pin.id))
      XCTAssertFalse(cold.beginPinnedBrowserRename(f.pin.id))
      XCTAssertTrue(cold.workspace.browser.tabs.isEmpty)
      XCTAssertEqual(cold.library.drafts,drafts); XCTAssertEqual(cold.selection,selection)
      await cold.openPinnedWorkspaceTab(f.pin.id)
      XCTAssertTrue(cold.canRenamePinnedBrowser(f.pin.id))
      XCTAssertTrue(cold.beginPinnedBrowserRename(f.pin.id))
      let request=try XCTUnwrap(cold.pinnedBrowserRenameRequest)
      XCTAssertEqual(request.initialTitle,"Original",taskWindow ? "task window source" : "main background source")
      XCTAssertTrue(cold.savePinnedBrowserRename(request,title:"Restored"))
      XCTAssertEqual(cold.library.pinnedContentTabs.first?.title,"Restored")
    }
  }
  func testCancelKeepsNameAndUnpinCancelsWithoutTargetingAnotherPin() throws {
    let f=try fixture()
    XCTAssertTrue(f.store.beginPinnedBrowserRename(f.pin.id))
    let request=try XCTUnwrap(f.store.pinnedBrowserRenameRequest)
    f.store.cancelPinnedBrowserRename("different")
    XCTAssertEqual(f.store.pinnedBrowserRenameRequest?.id,request.id)
    f.store.closePinnedBrowserRename(request)
    XCTAssertEqual(f.page.customTitle,"Original")
    XCTAssertTrue(f.store.beginPinnedBrowserRename(f.pin.id))
    let stale=try XCTUnwrap(f.store.pinnedBrowserRenameRequest)
    f.store.unpinWorkspaceTab(f.pin.id)
    XCTAssertNil(f.store.pinnedBrowserRenameRequest)
    f.store.addPinnedWorkspaceTab(f.pin)
    XCTAssertFalse(f.store.savePinnedBrowserRename(stale,title:"Stale"))
    XCTAssertEqual(f.page.customTitle,"Original")
  }
  func testHiddenActualWorkspaceMountsSidebarRenameInItsExistingWindowAndRemovesItOnClose() async throws {
    let f=try fixture()
    let window=NSWindow(contentRect:.init(x:0,y:0,width:1100,height:750),styleMask:[.titled,.closable],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false
    let host=NSHostingView(rootView:WorkspaceView(store:f.store)); window.contentView=host
    defer { window.contentView=nil; window.close() }
    func fields(_ view: NSView) -> [NSTextField] {
      (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    try await Task.sleep(for:.milliseconds(150)); host.layoutSubtreeIfNeeded()
    let windows=Set(NSApp.windows.map(\.windowNumber)),selection=f.store.selection
    XCTAssertTrue(f.store.beginPinnedBrowserRename(f.pin.id))
    let request=try XCTUnwrap(f.store.pinnedBrowserRenameRequest)
    try await Task.sleep(for:.milliseconds(150)); host.layoutSubtreeIfNeeded()
    let field=try XCTUnwrap(fields(host).first { $0.stringValue == "Original" && $0.isEditable })
    XCTAssertTrue(field.window === window)
    XCTAssertEqual(Set(NSApp.windows.map(\.windowNumber)),windows)
    XCTAssertEqual(f.store.selection,selection)
    f.store.closePinnedBrowserRename(request)
    try await Task.sleep(for:.milliseconds(150)); host.layoutSubtreeIfNeeded()
    XCTAssertFalse(fields(host).contains { $0 === field })
    XCTAssertFalse(f.store.mainRenameDialogActive)
    XCTAssertEqual(f.store.pinnedBrowserRenameReturnPinID,f.pin.id)
    XCTAssertEqual(f.page.customTitle,"Original")
  }
  func testNativeActualMainMountsSidebarModalInsideExistingWindowAndInlineEditorBlurSaves() async throws {
    guard ProcessInfo.processInfo.environment["SHIPIOS_TEST_FOREGROUND_ALLOWED"] == "1" else {
      throw XCTSkip("Requires an explicitly enabled interactive macOS AppKit test host; run script/test_macos_foreground.py.")
    }
    let f=try fixture(); f.store.applyTaskSelection(f.store.library.tasks[0])
    let policy=NSApp.activationPolicy()
    NSApp.setActivationPolicy(.regular)
    let window=NSWindow(contentRect:.init(x:0,y:0,width:1100,height:750),styleMask:[.titled,.closable],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false
    let host=NSHostingView(rootView:WorkspaceView(store:f.store)); window.contentView=host
    defer { window.contentView=nil; window.close(); NSApp.setActivationPolicy(policy) }
    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    try await Task.sleep(for:.milliseconds(250)); host.layoutSubtreeIfNeeded()
    XCTAssertTrue(window.isKeyWindow)
    f.store.activateWorkspaceTab(f.pin.sourceTabID)
    XCTAssertTrue(f.store.beginWorkspaceBrowserRename(f.pin.sourceTabID))
    try await Task.sleep(for:.milliseconds(170)); host.layoutSubtreeIfNeeded()
    let field=try XCTUnwrap(f.session.titleField)
    XCTAssertTrue(field.window === window)
    XCTAssertTrue(window.firstResponder === field.currentEditor())
    XCTAssertTrue(f.session.hasEditableFocus(tabID:f.page.id,in:window))
    let editor=try XCTUnwrap(field.currentEditor() as? NSTextView)
    editor.insertText("Inline saved",replacementRange:NSRange(location:0,length:editor.string.utf16.count))
    XCTAssertTrue(window.makeFirstResponder(host))
    try await Task.sleep(for:.milliseconds(100))
    XCTAssertEqual(f.page.customTitle,"Inline saved")
    XCTAssertNil(f.session.renameRequest)
    let visible=Set(nativeInteractionWindows().filter(\.isVisible).map(\.windowNumber))
    XCTAssertTrue(f.store.beginPinnedBrowserRename(f.pin.id))
    try await Task.sleep(for:.milliseconds(170)); host.layoutSubtreeIfNeeded()
    XCTAssertEqual(Set(nativeInteractionWindows().filter(\.isVisible).map(\.windowNumber)),visible,
      NSApp.windows.filter(\.isVisible).map { "\($0.windowNumber): \(type(of: $0)) title=\($0.title) level=\($0.level.rawValue)" }.joined(separator: "; "))
    XCTAssertTrue(window.isKeyWindow)
    let modalEditor=try XCTUnwrap(window.firstResponder as? NSTextView)
    XCTAssertTrue(modalEditor.isFieldEditor)
    XCTAssertEqual(modalEditor.string,"Inline saved")
    XCTAssertEqual(modalEditor.selectedRange(),NSRange(location:0,length:modalEditor.string.utf16.count))
    XCTAssertTrue(f.store.mainRenameDialogActive)
    let request=try XCTUnwrap(f.store.pinnedBrowserRenameRequest)
    f.store.closePinnedBrowserRename(request)
    try await Task.sleep(for:.milliseconds(150))
    XCTAssertFalse(f.store.mainRenameDialogActive)
    XCTAssertEqual(f.store.pinnedBrowserRenameReturnPinID,f.pin.id)
    XCTAssertEqual(f.page.customTitle,"Inline saved")
    XCTAssertNil(f.session.titleField)
  }

  func testNativeRenameMountedBeforeWindowBecomesKeyFocusesOnlyOnce() async throws {
    guard ProcessInfo.processInfo.environment["SHIPIOS_TEST_FOREGROUND_ALLOWED"] == "1" else {
      throw XCTSkip("Requires the interactive AppKit test host.")
    }
    let f = try fixture()
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 750),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: WorkspaceView(store: f.store))
    window.contentView = host
    defer { window.contentView = nil; window.close() }
    XCTAssertTrue(f.store.beginPinnedBrowserRename(f.pin.id))
    try await Task.sleep(for: .milliseconds(200))
    host.layoutSubtreeIfNeeded()
    XCTAssertFalse(window.isKeyWindow)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    try await Task.sleep(for: .milliseconds(250))
    host.layoutSubtreeIfNeeded()
    XCTAssertTrue(window.isKeyWindow)
    let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
    XCTAssertTrue(editor.isFieldEditor)
    XCTAssertEqual(editor.string, "Original")
    XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: editor.string.utf16.count))
    editor.insertText("User edit", replacementRange: editor.selectedRange())
    XCTAssertEqual(editor.selectedRange(), NSRange(location: "User edit".utf16.count, length: 0))
    window.orderOut(nil)
    window.makeKeyAndOrderFront(nil)
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertTrue(window.isKeyWindow)
    let returnedEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
    XCTAssertEqual(returnedEditor.string, "User edit")
    XCTAssertEqual(returnedEditor.selectedRange(), NSRange(location: "User edit".utf16.count, length: 0),
      "Later activation must not select the user's edited name again")
    let request = try XCTUnwrap(f.store.pinnedBrowserRenameRequest)
    f.store.closePinnedBrowserRename(request)
    XCTAssertEqual(f.page.customTitle, "Original", "Closing without saving keeps the original title")
  }
}
