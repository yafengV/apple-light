import AppKit
import WebKit
import XCTest
@testable import ShipiOS

@MainActor final class PinnedBrowserActionTests: XCTestCase {
  private struct Fixture {
    let store: WorkspaceStore, session: BrowserSession, page: BrowserTab, pin: PinnedWorkspaceTab
    let resources: TaskWindowResources?
  }
  private struct Reference: Decodable {
    struct Sample: Decodable {
      struct Snapshot: Decodable { let tabType: String, url: String }
      struct Item: Decodable { let id: String }
      struct Duplicate: Decodable {
        struct Args: Decodable {
          struct Insertion: Decodable { let type: String, tabId: String }
          struct Command: Decodable { let url: String? }
          let openerTabId, target: String?
          let revealAndFocus: Bool?
          let insertPosition: Insertion?
          let command: Command?
        }
        let kind: String, args: Args
      }
      let name: String, snapshot: Snapshot?, defaultBrowser: Bool?, items: [Item], duplicate: [Duplicate]
      let staleCallbacks: [String]
    }
    let cases: [Sample]
    static func load() throws -> Self {
      let url = try XCTUnwrap(Bundle.module.url(forResource: "pinned_browser_menu_reference_724", withExtension: "json", subdirectory: "Fixtures"))
      return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
  }
  private func fixture(taskWindow: Bool = false) throws -> Fixture {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pinned-actions-\(UUID())")
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true; store.scopeLoaded = true
    store.modelConfiguration.model = ""; store.modelConfiguration.baseURL = ""
    store.library.tasks = [.init(id: "a", project: "", title: "A", runIDs: []), .init(id: "b", project: "", title: "B", runIDs: [])]
    store.library.drafts = ["a": "Source draft", "b": "中文主草稿"]
    store.applyTaskSelection(store.library.tasks[0])
    let resources: TaskWindowResources?, session: BrowserSession, tabID: String
    if taskWindow {
      let owner = TaskWindowResources(); owner.prepare("a", store: store, windowID: "source-window"); owner.display("a")
      let tabs = try XCTUnwrap(owner.tasks["a"]); tabs.newBrowser(in: .right)
      session = tabs.browser.session; tabID = try XCTUnwrap(tabs.focusedID); resources = owner
    } else {
      store.newBrowserTab(in: .right); session = store.workspace.browser
      tabID = try XCTUnwrap(store.focusedWorkspaceContentTab?.id); resources = nil
    }
    let page = try XCTUnwrap(session.selected); page.setCustomTitle("Original")
    if let resources { resources.pin(tabID, taskID: "a") } else { store.pinWorkspaceTab(tabID) }
    let pin = try XCTUnwrap(store.library.pinnedContentTabs.first)
    store.applyTaskSelection(store.library.tasks[1])
    addTeardownBlock { @MainActor in
      store.cancelPinnedBrowserRename(); resources?.shutdown(); store.workspace.browser.shutdown()
      try? FileManager.default.removeItem(at: root)
    }
    return .init(store: store, session: session, page: page, pin: pin, resources: resources)
  }

  func testImplementedMenuActionsMatchActualReferenceOrderAndConditionalURLs() throws {
    let reference = try Reference.load(); XCTAssertEqual(reference.cases.count, 9)
    for sample in reference.cases {
      let url = sample.snapshot.flatMap { URL(string: $0.url) }
      let actual = PinnedBrowserAction.available(url: url, isWeb: sample.snapshot?.tabType == "WEB", isDefaultBrowser: sample.defaultBrowser ?? false).map(\.rawValue)
      // Audio/fork capabilities are retained in the full source fixture, not claimed implemented.
      let supported = sample.items.map(\.id).filter { PinnedBrowserAction(rawValue: $0) != nil }
      XCTAssertEqual(actual, supported, sample.name)
      XCTAssertTrue(sample.staleCallbacks.isEmpty)
      let duplicate = try XCTUnwrap(sample.duplicate.first)
      XCTAssertEqual(duplicate.kind, "new"); XCTAssertEqual(duplicate.args.target, "right")
      let insertion = try XCTUnwrap(duplicate.args.insertPosition)
      XCTAssertEqual(insertion.type, "after")
      XCTAssertEqual(insertion.tabId, duplicate.args.openerTabId)
      XCTAssertEqual(duplicate.args.revealAndFocus, true)
      XCTAssertEqual(sample.duplicate.first { $0.kind == "navigate" }?.args.command?.url, sample.snapshot?.url ?? "")
    }
    XCTAssertTrue(try XCTUnwrap(reference.cases.first { $0.name == "loaded-web" }).items.contains { $0.id == "mute-browser-tab" })
    XCTAssertTrue(try XCTUnwrap(reference.cases.first { $0.name == "forkable-web" }).items.contains { $0.id == "fork-browser-tab" })
  }

  func testDuplicateFromBothSourcesRetainsOwnerPaneAndOpenerWithoutChangingMain() throws {
    for window in [false, true] {
      let f = try fixture(taskWindow: window), context = try XCTUnwrap(f.store.pinnedBrowserActionContext(f.pin.id, isDefaultBrowser: false))
      let layout = f.store.workspaceTabLayoutSnapshot, selection = f.store.selection, drafts = f.store.library.drafts
      XCTAssertTrue(f.store.performPinnedBrowserAction(.duplicate, context: context))
      let child = try XCTUnwrap(f.session.tabs.last); XCTAssertFalse(child === f.page)
      XCTAssertNil(child.customTitle); XCTAssertEqual(child.address, "")
      let id = "browser:\(child.id)"
      if let tabs = f.resources?.tasks["a"] {
        let index = try XCTUnwrap(tabs.tabs.firstIndex { $0.id == f.pin.sourceTabID })
        XCTAssertEqual(tabs.tabs[index + 1].id, id); XCTAssertEqual(tabs.tabs[index + 1].owner, "a")
        XCTAssertEqual(tabs.placement(id), .right); XCTAssertEqual(tabs.focusedID, id)
      } else {
        let index = try XCTUnwrap(f.store.workspaceTabs.firstIndex { $0.id == f.pin.sourceTabID })
        XCTAssertEqual(f.store.workspaceTabs[index + 1].id, id); XCTAssertEqual(f.store.workspaceTabs[index + 1].owner, "a")
        XCTAssertEqual(f.store.workspaceTabPlacement(id), .right)
        XCTAssertEqual(f.store.library.workspaceTabLayouts["a"]?.tabs[index + 1].id, id)
        XCTAssertEqual(f.store.library.workspaceTabLayouts["a"]?.right, id)
        XCTAssertEqual(f.store.library.workspaceTabLayouts["a"]?.focused, id)
      }
      XCTAssertEqual(f.store.selection, selection); XCTAssertEqual(f.store.library.drafts, drafts)
      XCTAssertEqual(f.store.workspaceTabLayoutSnapshot, layout)
    }
  }

  func testOldActionsRejectUnpinReaddReplacementOwnerProjectPaneDragAndWindowLoss() throws {
    for window in [false, true] {
      for mutation in ["unpin-readd", "replace", "owner", "project", "pane", "drag", "closed", "pin-value", "window"] {
        let f = try fixture(taskWindow: window), context = try XCTUnwrap(f.store.pinnedBrowserActionContext(f.pin.id))
        switch mutation {
        case "unpin-readd": f.store.unpinWorkspaceTab(f.pin.id); f.store.library.pinnedContentTabs.append(f.pin); _ = f.store.pinnedBrowserActionContext(f.pin.id)
        case "replace": f.session.close(f.page.id); _ = f.session.newTab(activate: false, id: f.page.id)
        case "owner": f.store.library.pinnedContentTabs[0].owner = "b"
        case "project": f.store.library.tasks[0].project = "/other"
        case "pane":
          if let tabs = f.resources?.tasks["a"] { tabs.move(f.pin.sourceTabID, to: .left) }
          else { f.store.workspaceTabPlacements[f.pin.sourceTabID] = .left }
        case "drag":
          if let tabs = f.resources?.tasks["a"] { _ = tabs.beginDrag(f.pin.sourceTabID) }
          else { f.store.draggingWorkspaceTabID = f.pin.sourceTabID }
        case "closed": f.page.close()
        case "pin-value": f.store.library.pinnedContentTabs[0].title = "Replacement metadata"
        default: if let resources = f.resources { resources.shutdown() } else { f.store.shuttingDown = true }
        }
        XCTAssertFalse(f.store.pinnedBrowserActionIsCurrent(context), "\(window) \(mutation)")
        var opened = 0
        for action in context.actions {
          XCTAssertFalse(f.store.performPinnedBrowserAction(action, context: context, openExternal: { _ in opened += 1; return true }))
        }
        XCTAssertEqual(opened, 0); XCTAssertEqual(f.store.selection, "b")
      }
    }
  }

  func testColdAndModalSourcesDoNotRestoreOrRunActionsAndRenameUsesSameRequest() throws {
    let f = try fixture(), context = try XCTUnwrap(f.store.pinnedBrowserActionContext(f.pin.id))
    XCTAssertTrue(f.store.performPinnedBrowserAction(.rename, context: context))
    let request = try XCTUnwrap(f.store.pinnedBrowserRenameRequest)
    for action in context.actions { XCTAssertFalse(f.store.performPinnedBrowserAction(action, context: context)) }
    f.store.closePinnedBrowserRename(request)
    f.session.close(f.page.id)
    let selection = f.store.selection, tabs = f.store.workspaceTabs
    XCTAssertNil(f.store.pinnedBrowserActionContext(f.pin.id))
    XCTAssertEqual(f.store.selection, selection); XCTAssertEqual(f.store.workspaceTabs, tabs)
    XCTAssertEqual(f.store.restoringPinnedContentTabIDs, [])
  }

  func testRealLocalPageReloadDuplicateClipboardExternalAndClosePreserveScopeAndLatestURL() async throws {
    let server = Process(), output = Pipe()
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/browser_server.py")
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); server.arguments = ["-u", script.path]
    server.standardOutput = output; server.standardError = FileHandle.nullDevice
    try server.run(); defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
    let port = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertNotNil(Int(port)); let base = "http://127.0.0.1:\(port)"
    for window in [false, true] {
      let f = try fixture(taskWindow: window)
      f.page.address = base + "/one"; f.page.navigate()
      try await eventually { f.page.pageTitle == "One" && !f.page.loading && f.page.error == nil }
      let context = try XCTUnwrap(f.store.pinnedBrowserActionContext(f.pin.id, isDefaultBrowser: false))
      let layout = f.store.workspaceTabLayoutSnapshot, drafts = f.store.library.drafts
      f.page.setAddressDraft(base + "/unsubmitted")
      let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
      XCTAssertTrue(f.store.performPinnedBrowserAction(.copyURL, context: context, pasteboard: pasteboard))
      XCTAssertEqual(pasteboard.string(forType: .string), base + "/one")
      let notice = try XCTUnwrap((f.resources?.notices ?? f.store.notices).items.first { $0.id == "browser-url-copied" })
      XCTAssertEqual(notice.title, "URL 已复制到剪贴板"); XCTAssertEqual(notice.taskID, "a")
      if window { XCTAssertTrue(f.store.notices.items.isEmpty) }
      var opened: [URL] = []
      XCTAssertTrue(f.store.performPinnedBrowserAction(.openExternal, context: context, openExternal: { opened.append($0); return true }))
      XCTAssertEqual(opened.map(\.absoluteString), [base + "/one"])
      let revision = f.page.siteToolsRevision
      XCTAssertTrue(f.store.performPinnedBrowserAction(.reload, context: context))
      XCTAssertNotEqual(f.page.siteToolsRevision, revision)
      try await eventually { !f.page.loading && f.page.error == nil }
      XCTAssertTrue(f.store.performPinnedBrowserAction(.duplicate, context: context))
      let child = try XCTUnwrap(f.session.tabs.last)
      try await eventually { child.pageTitle == "One" && !child.loading && child.error == nil }
      XCTAssertEqual(child.committedURL?.absoluteString, base + "/one")
      XCTAssertFalse(child.address.contains("unsubmitted"))
      f.page.address = base + "/two"; f.page.navigate()
      try await eventually { f.page.pageTitle == "Two" && !f.page.loading }
      let current = try XCTUnwrap(f.store.pinnedBrowserActionContext(f.pin.id, isDefaultBrowser: false))
      XCTAssertTrue(f.store.performPinnedBrowserAction(.copyURL, context: current, pasteboard: pasteboard))
      XCTAssertEqual(pasteboard.string(forType: .string), base + "/two")
      XCTAssertTrue(f.store.performPinnedBrowserAction(.close, context: current))
      XCTAssertTrue(f.page.closed); XCTAssertNil(f.session.tabs.first { $0 === f.page })
      let saved = try JSONDecoder().decode(WorkspaceLibrary.self, from: Data(contentsOf: f.store.dataRoot.appendingPathComponent("workspace.json")))
      let pin = try XCTUnwrap(saved.pinnedContentTabs.first { $0.id == f.pin.id })
      XCTAssertEqual(pin.restoreURL, base + "/two"); XCTAssertEqual(pin.browserCustomTitle, "Original")
      XCTAssertNil(f.store.pinnedBrowserActionContext(f.pin.id))
      XCTAssertEqual(f.store.selection, "b"); XCTAssertEqual(f.store.library.drafts, drafts)
      XCTAssertEqual(f.store.workspaceTabLayoutSnapshot, layout)
    }
  }
  func testBlankWebURLCannotCopyButDuplicatesWithoutAddressValidationFailure() async throws {
    let f = try fixture()
    f.page.view.loadHTMLString("<title>Blank</title><p>local</p>", baseURL: nil)
    try await eventually { f.page.committedURL?.absoluteString == "about:blank" && !f.page.loading }
    let context = try XCTUnwrap(f.store.pinnedBrowserActionContext(f.pin.id, isDefaultBrowser: false))
    XCTAssertFalse(context.actions.contains(.copyURL))
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    board.setString("Keep clipboard", forType: .string)
    XCTAssertFalse(f.store.performPinnedBrowserAction(.copyURL, context: context, pasteboard: board))
    XCTAssertEqual(board.string(forType: .string), "Keep clipboard")
    XCTAssertTrue(f.store.performPinnedBrowserAction(.duplicate, context: context))
    let child = try XCTUnwrap(f.session.tabs.last)
    try await eventually { child.committedURL?.absoluteString == "about:blank" && !child.loading }
    XCTAssertNil(child.error); XCTAssertEqual(child.address, "about:blank")
    XCTAssertEqual(f.store.selection, "b")
  }

  private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<320 { if condition() { return }; try await Task.sleep(for: .milliseconds(25)) }
    XCTFail("Local browser operation did not complete")
    throw AgentFailure(message: "Local fixture timed out")
  }
}
