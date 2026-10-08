import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class ContentTabTransferSelectionTests: XCTestCase {
  private final class KeyWindow: NSWindow { override var isKeyWindow: Bool { true } }
  private func composer(in view: NSView) -> ComposerNativeTextView? {
    (view as? ComposerNativeTextView) ?? view.subviews.lazy.compactMap { self.composer(in: $0) }.first
  }
  private struct Reference: Decodable {
    struct History: Decodable {
      struct Entry: Decodable { let generation: Int; let openerTabId: String }
      let active: Bool; let generation: Int; let lastSelectedTabId: String?; let tabs: [String: Entry]
    }
    struct Step: Decodable {
      let action: String; let id: String?; let opener: String?
      let ids: [String]; let selected: String?; let recent: [String]; let history: History; let moved: String?
    }
    struct Trace: Decodable {
      struct Initial: Decodable { let ids: [String]; let selected: String?; let home: String? }
      let name: String; let initial: Initial; let steps: [Step]
    }
    let traces: [Trace]
  }
  func testControllerTransferMatchesActualReferenceRecencyAndFamilyState() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "content_transfer_reference_698", withExtension: "json", subdirectory: "Fixtures"))
    let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    XCTAssertEqual(reference.traces.count, 18)
    let supported = reference.traces.filter { $0.initial.home == nil }
    XCTAssertEqual(supported.count, 17, "Workspace-home policy belongs to the pending primary-workspace implementation")
    for trace in supported {
      var ids = trace.initial.ids, controller = ContentTabCloseController()
      controller.selectedID = trace.initial.selected
      for (index, step) in trace.steps.enumerated() {
        let label = "\(trace.name) \(index): \(step.action)"
        var moved: String?
        switch step.action {
        case "select": controller.select(step.id, in: ids)
        case "open":
          let id = try XCTUnwrap(step.id)
          ids.insert(id, at: step.opener.flatMap { ids.firstIndex(of: $0) }.map { $0 + 1 } ?? ids.count)
          if let opener = step.opener { controller.history.opened(id, by: opener, background: false) }
          controller.select(id, in: ids)
        case "transfer":
          let id = try XCTUnwrap(step.id)
          moved = ids.contains(id) ? id : nil
          _ = controller.transfer(id, in: ids); ids.removeAll { $0 == id }
        default: XCTFail(label)
        }
        XCTAssertEqual(ids, step.ids, label); XCTAssertEqual(controller.selectedID, step.selected, label)
        XCTAssertEqual(controller.recentSelectedIDs, step.recent, label); XCTAssertEqual(moved, step.moved, label)
        XCTAssertEqual(controller.history.active, step.history.active, label)
        XCTAssertEqual(controller.history.generation, step.history.generation, label)
        XCTAssertEqual(controller.history.lastSelectedTabID, step.history.lastSelectedTabId, label)
        XCTAssertEqual(controller.history.tabs, step.history.tabs.mapValues { .init(generation: $0.generation, openerTabID: $0.openerTabId) }, label)
      }
    }
  }
  private func fixture() throws -> (WorkspaceStore, URL) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath().standardizedFileURL
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("data"))
    store.libraryLoaded = true; store.scopeLoaded = true; store.connected = true
    store.library.tasks = ["a", "b", "c"].map { .init(id: $0, project: root.path, title: $0, runIDs: []) }
    store.project = root; store.workspace.setProject(root); store.applyTaskSelection(store.library.tasks[0])
    return (store, root)
  }
  private func browser(_ store: WorkspaceStore, mode: WorkspaceContentLayoutMode) throws -> WorkspaceContentTab {
    store.newBrowserTab(in: mode == .full ? .left : .right)
    return try XCTUnwrap(mode == .full ? store.activeWorkspaceContentTab : store.activeRightWorkspaceContentTab)
  }

  func testTransferActiveUsesRecentSelectionBeforeRightNeighborAndKeepsWebView() throws {
    for mode in [WorkspaceContentLayoutMode.full, .split] {
      let (store, _) = try fixture(); defer { store.workspace.browser.shutdown() }
      let a = try browser(store, mode: mode), b = try browser(store, mode: mode)
      let c = try browser(store, mode: mode), d = try browser(store, mode: mode)
      store.activateWorkspaceTab(a.id); store.activateWorkspaceTab(c.id)
      let page = try XCTUnwrap(store.workspace.browser.tabs.first { $0.id == c.browserID })
      XCTAssertEqual(store.moveWorkspaceTab(c.id, toOwner: "b"), c.id)
      XCTAssertEqual(store.visibleWorkspaceContentTabs, [a, b, d])
      XCTAssertEqual(mode == .full ? store.activeWorkspaceContentTab : store.activeRightWorkspaceContentTab, a)
      XCTAssertEqual(store.focusedWorkspaceContentTab, a)
      XCTAssertEqual(store.workspace.browser.selection, a.browserID)
      XCTAssertEqual(store.library.workspaceTabLayouts["a"]?.focused, a.id)
      XCTAssertFalse(store.library.workspaceTabLayouts["a"]?.tabs.contains { $0.id == c.id } == true)
      XCTAssertTrue(store.workspace.browser.tabs.first { $0.id == c.browserID } === page)
      XCTAssertFalse(page.closed)
      XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode, mode)
    }
  }

  func testTransferInactiveLeavesSourceSelectionAndFocusUnchanged() throws {
    let (store, _) = try fixture(); defer { store.workspace.browser.shutdown() }
    let first = try browser(store, mode: .full), selected = try browser(store, mode: .full)
    let address = store.workspace.browser.addressFocus, content = store.workspace.browser.contentFocus
    XCTAssertEqual(store.moveWorkspaceTab(first.id, toOwner: "b"), first.id)
    XCTAssertEqual(store.activeWorkspaceContentTab, selected); XCTAssertEqual(store.focusedWorkspaceContentTab, selected)
    XCTAssertEqual(store.workspace.browser.addressFocus, address); XCTAssertEqual(store.workspace.browser.contentFocus, content)
    XCTAssertEqual(store.library.workspaceTabLayouts["b"]?.tabs.map(\.id), [first.id])
  }

  func testTransferRepairsSourceBeforeTargetNavigationAndAppendsToPersistedTarget() async throws {
    let (store, _) = try fixture(); defer { store.workspace.browser.shutdown() }
    let sourceFirst = try browser(store, mode: .full), moved = try browser(store, mode: .full)
    store.applyTaskSelection(store.library.tasks[1])
    let targetFirst = try browser(store, mode: .full), targetSecond = try browser(store, mode: .full)
    store.applyTaskSelection(store.library.tasks[0]); store.activateWorkspaceTab(moved.id)
    let result = await store.moveWorkspaceTab(moved.id, toTaskID: "b")
    XCTAssertTrue(result); XCTAssertEqual(store.selection, "b")
    XCTAssertEqual(store.visibleWorkspaceContentTabs.map(\.id), [targetFirst.id, targetSecond.id, moved.id])
    XCTAssertEqual(store.activeWorkspaceContentTab?.id, moved.id)
    XCTAssertEqual(store.library.workspaceTabLayouts["a"]?.active, sourceFirst.id)
    XCTAssertEqual(store.library.workspaceTabLayouts["a"]?.focused, sourceFirst.id)
    XCTAssertEqual(store.library.workspaceTabLayouts["b"]?.tabs.map(\.id), [targetFirst.id, targetSecond.id, moved.id])
    let decoded = try JSONDecoder().decode(WorkspaceLibrary.self, from: JSONEncoder().encode(store.library))
    XCTAssertEqual(decoded.workspaceTabLayouts["a"]?.active, sourceFirst.id)
    XCTAssertEqual(decoded.workspaceTabLayouts["b"]?.active, moved.id)
  }

  func testTransferBackgroundOwnerRepairsOnlyItsSavedLayout() throws {
    let (store, _) = try fixture(); defer { store.workspace.browser.shutdown() }
    let sourceFirst = try browser(store, mode: .full), moved = try browser(store, mode: .full)
    store.applyTaskSelection(store.library.tasks[1]); let current = try browser(store, mode: .full)
    let address = store.workspace.browser.addressFocus, content = store.workspace.browser.contentFocus
    XCTAssertEqual(store.moveWorkspaceTab(moved.id, toOwner: "c"), moved.id)
    XCTAssertEqual(store.selection, "b"); XCTAssertEqual(store.focusedWorkspaceContentTab, current)
    XCTAssertEqual(store.workspace.browser.selection, current.browserID)
    XCTAssertEqual(store.workspace.browser.addressFocus, address); XCTAssertEqual(store.workspace.browser.contentFocus, content)
    XCTAssertEqual(store.library.workspaceTabLayouts["a"]?.active, sourceFirst.id)
    XCTAssertEqual(store.library.workspaceTabLayouts["c"]?.tabs.map(\.id), [moved.id])
    XCTAssertFalse(store.library.workspaceTabLayouts["a"]?.tabs.contains { $0.id == moved.id } == true)
  }

  func testTransferLastCurrentContentReturnsToChatWithoutForeignSelectedID() throws {
    let (store, _) = try fixture(); defer { store.workspace.browser.shutdown() }
    let moved = try browser(store, mode: .full), oldFocus = store.focusComposer
    XCTAssertEqual(store.moveWorkspaceTab(moved.id, toOwner: "b"), moved.id)
    XCTAssertNil(store.activeWorkspaceContentTab); XCTAssertNil(store.activeWorkspaceTabID)
    XCTAssertNil(store.focusedWorkspaceTabID); XCTAssertNotEqual(store.focusComposer, oldFocus)
    XCTAssertTrue(store.visibleWorkspaceContentTabs.isEmpty)
    XCTAssertEqual(store.library.workspaceTabLayouts["b"]?.active, moved.id)
  }

  func testTransferSavedFileRekeysPinAndEditorWithoutLeavingForeignSelection() async throws {
    let (store, root) = try fixture(); let path = root.appendingPathComponent("file.txt")
    try "original".write(to: path, atomically: true, encoding: .utf8)
    XCTAssertTrue(store.openFileTab("file.txt")); let moved = try XCTUnwrap(store.activeWorkspaceContentTab)
    let editor = store.fileTabWorkspace(moved); editor.root = root; await editor.openFile("file.txt")
    store.pinWorkspaceTab(moved.id)
    let survivor = WorkspaceContentTab.review(owner: "a"); store.workspaceTabs.append(survivor)
    let target = WorkspaceContentTab.file("file.txt", owner: "b")
    XCTAssertEqual(store.moveWorkspaceTab(moved.id, toOwner: "b"), target.id)
    XCTAssertEqual(store.activeWorkspaceContentTab, survivor); XCTAssertEqual(store.focusedWorkspaceContentTab, survivor)
    XCTAssertTrue(store.fileTabWorkspaces[target.id] === editor); XCTAssertNil(store.fileTabWorkspaces[moved.id])
    XCTAssertEqual(store.library.pinnedContentTabs.first?.sourceTabID, target.id)
    XCTAssertEqual(store.library.pinnedContentTabs.first?.owner, "b")
    XCTAssertEqual(store.library.workspaceTabLayouts["b"]?.tabs.first?.filePath, "file.txt")
  }

  func testDraftPromotionPreservesOpenerReturn() throws {
    let (store, _) = try fixture(); defer { store.workspace.browser.shutdown() }
    let opener = try browser(store, mode: .full); _ = try browser(store, mode: .full)
    let child = try XCTUnwrap(store.newBrowserChild(from: try XCTUnwrap(opener.browserID)))
    store.moveWorkspaceTabs(from: "a", to: "b")
    store.applyTaskSelection(store.library.tasks[1])
    let id = WorkspaceContentTab.browser(child.id, owner: "b").id
    store.activateWorkspaceTab(id); store.closeWorkspaceTab(id)
    XCTAssertEqual(store.activeWorkspaceContentTab?.id, opener.id)
  }

  func testFileTransferCannotRetargetAnotherProjectsSameRelativeFilename() throws {
    let (store, root) = try fixture(), other = root.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try "source".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    try "different".write(to: other.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    store.library.tasks[1].project = other.path
    XCTAssertTrue(store.openFileTab("file.txt")); let tab = try XCTUnwrap(store.activeWorkspaceContentTab)
    XCTAssertNil(store.moveWorkspaceTab(tab.id, toOwner: "b"))
    XCTAssertEqual(store.activeWorkspaceContentTab, tab); XCTAssertTrue(store.workspaceTabs.contains(tab))
    XCTAssertEqual(try String(contentsOf: other.appendingPathComponent("file.txt"), encoding: .utf8), "different")
  }

  func testFileTransferToAssociatedSourceFolderKeepsAbsoluteFileIdentity() throws {
    let (store, root) = try fixture(), other = root.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try "source".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    store.library.tasks[1].project = other.path
    store.library.projectAdditionalFolders[other.path] = [root.path]
    XCTAssertTrue(store.openFileTab("file.txt")); let tab = try XCTUnwrap(store.activeWorkspaceContentTab)
    let actual = root.appendingPathComponent("file.txt").resolvingSymlinksInPath().path
    let expected = WorkspaceContentTab.file(actual, owner: "b")
    XCTAssertEqual(store.moveWorkspaceTab(tab.id, toOwner: "b"), expected.id)
    XCTAssertTrue(store.workspaceTabs.contains(expected))
    XCTAssertEqual(store.library.workspaceTabLayouts["b"]?.tabs.first?.filePath, actual)
  }

  func testMissingDestinationCannotMutateSelectionOrNavigationHistory() throws {
    let (store, _) = try fixture(); defer { store.workspace.browser.shutdown() }
    let first = try browser(store, mode: .full), selected = try browser(store, mode: .full)
    store.library.tasks.removeAll { $0.id == "b" }
    let tabs = store.workspaceTabs, address = store.workspace.browser.addressFocus
    XCTAssertNil(store.moveWorkspaceTab(selected.id, toOwner: "b"))
    XCTAssertEqual(store.workspaceTabs, tabs); XCTAssertEqual(store.activeWorkspaceContentTab, selected)
    XCTAssertEqual(store.workspace.browser.addressFocus, address)
    store.closeWorkspaceTab(selected.id)
    XCTAssertEqual(store.activeWorkspaceContentTab, first)
  }

  func testUnvisitedTargetRestoresSavedOrderAroundAlreadyLiveReceivedTab() throws {
    let (store, root) = try fixture(); defer { store.workspace.browser.shutdown() }
    let moved = try browser(store, mode: .full)
    let old = WorkspaceContentTab.browser(UUID(), owner: "b")
    store.library.workspaceTabLayouts["b"] = .init(tabs: [
      .init(id: old.id, kind: .browser, placement: .left)
    ], active: old.id, showingInspector: false, showingTerminal: false, showingTabs: true,
      side: .left, reviewScope: .unstaged, contentLayoutMode: .full)
    XCTAssertEqual(store.moveWorkspaceTab(moved.id, toOwner: "b"), moved.id)
    XCTAssertEqual(store.library.workspaceTabLayouts["b"]?.tabs.map(\.id), [old.id, moved.id])
    store.applyTaskSelection(store.library.tasks[1])
    XCTAssertEqual(store.visibleWorkspaceContentTabs.map(\.id), [old.id, moved.id])
    XCTAssertEqual(store.activeWorkspaceContentTab?.id, moved.id)
    let restored = WorkspaceStore(dataRoot: root.appendingPathComponent("cold")); defer { restored.workspace.browser.shutdown() }
    restored.library = store.library; restored.libraryLoaded = true; restored.scopeLoaded = true; restored.connected = true
    restored.project = root; restored.workspace.setProject(root); restored.applyTaskSelection(restored.library.tasks[1])
    XCTAssertEqual(restored.visibleWorkspaceContentTabs.map(\.id), [old.id, moved.id])
    XCTAssertEqual(restored.activeWorkspaceContentTab?.id, moved.id)
  }

  func testFailedFileMoveDoesNotSwitchProjectOrStopCurrentConnection() async throws {
    let (store, root) = try fixture(), other = root.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try "source".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    store.library.tasks[1].project = other.path
    XCTAssertTrue(store.openFileTab("file.txt")); let tab = try XCTUnwrap(store.activeWorkspaceContentTab)
    store.draft = "keep draft"
    let moved = await store.moveWorkspaceTab(tab.id, toTaskID: "b")
    XCTAssertFalse(moved); XCTAssertEqual(store.project, root); XCTAssertEqual(store.selection, "a")
    XCTAssertTrue(store.connected); XCTAssertFalse(store.busy)
    XCTAssertEqual(store.draft, "keep draft"); XCTAssertEqual(store.activeWorkspaceContentTab, tab)
  }

  func testUnsupportedMoveToNewDraftDoesNotChangeSelectionOrDraft() async throws {
    let (store, _) = try fixture()
    let tab = WorkspaceContentTab.sources(owner: "a"); store.workspaceTabs.append(tab); store.activateWorkspaceTab(tab.id)
    store.draft = "keep draft"; let focus = store.focusComposer
    let moved = await store.moveWorkspaceTabToNewTask(tab.id)
    XCTAssertFalse(moved); XCTAssertEqual(store.selection, "a"); XCTAssertEqual(store.draft, "keep draft")
    XCTAssertEqual(store.activeWorkspaceContentTab, tab); XCTAssertEqual(store.focusComposer, focus)
  }

  func testTransferringExplicitChildReturnsToPreviousContentRatherThanOpener() throws {
    let (store, _) = try fixture(); defer { store.workspace.browser.shutdown() }
    let opener = try browser(store, mode: .full), previous = try browser(store, mode: .full)
    let child = try XCTUnwrap(store.newBrowserChild(from: try XCTUnwrap(opener.browserID)))
    let id = WorkspaceContentTab.browser(child.id, owner: "a").id
    XCTAssertEqual(store.moveWorkspaceTab(id, toOwner: "b"), id)
    XCTAssertEqual(store.activeWorkspaceContentTab, previous)
    XCTAssertNotEqual(store.activeWorkspaceContentTab, opener)
  }

  func testBottomTransferUsesRecentTerminalAndKeepsAllShellInstances() throws {
    let (store, _) = try fixture(); defer { store.workspace.terminals.shutdown() }
    store.newTerminalTab(); let first = try XCTUnwrap(store.activeBottomWorkspaceContentTab)
    store.newTerminalTab(); let moved = try XCTUnwrap(store.activeBottomWorkspaceContentTab)
    store.newTerminalTab(); let last = try XCTUnwrap(store.activeBottomWorkspaceContentTab)
    let sessions = try [first, moved, last].map { try XCTUnwrap(store.terminalSession(try XCTUnwrap($0.terminalID))) }
    let pids = sessions.map { $0.view.process.shellPid }
    store.activateWorkspaceTab(first.id); store.activateWorkspaceTab(moved.id)
    XCTAssertEqual(store.moveWorkspaceTab(moved.id, toOwner: "b"), moved.id)
    XCTAssertEqual(store.activeBottomWorkspaceContentTab, first); XCTAssertEqual(store.focusedWorkspaceContentTab, first)
    XCTAssertEqual(store.library.workspaceTabLayouts["b"]?.bottom, moved.id)
    XCTAssertEqual(store.terminalScope(for: try XCTUnwrap(store.workspaceTabs.first { $0.id == moved.id }))?.conversation, "b")
    for (session, pid) in zip(sessions, pids) { XCTAssertEqual(session.view.process.shellPid, pid); XCTAssertTrue(session.view.process.running) }
    XCTAssertTrue(store.terminalSession(try XCTUnwrap(moved.terminalID)) === sessions[1])
  }

  func testDraftPromotionRekeysRecentFileAndReviewIDs() throws {
    let (store, root) = try fixture()
    try Data().write(to: root.appendingPathComponent("file.txt"))
    let review = WorkspaceContentTab.review(owner: "a"); store.workspaceTabs.append(review); store.activateWorkspaceTab(review.id)
    XCTAssertTrue(store.openFileTab("file.txt"))
    store.moveWorkspaceTabs(from: "a", to: "b"); store.applyTaskSelection(store.library.tasks[1])
    let file = WorkspaceContentTab.file("file.txt", owner: "b"), movedReview = WorkspaceContentTab.review(owner: "b")
    store.activateWorkspaceTab(file.id)
    XCTAssertEqual(store.moveWorkspaceTab(file.id, toOwner: "c"), WorkspaceContentTab.file("file.txt", owner: "c").id)
    XCTAssertEqual(store.activeWorkspaceContentTab, movedReview); XCTAssertEqual(store.focusedWorkspaceContentTab, movedReview)
  }

  func testBrowserAddressFocusRequestSurvivesDelayedNativeAttachment() async throws {
    let (store, _) = try fixture(); defer { store.workspace.browser.shutdown() }
    let tab = try browser(store, mode: .full)
    let page = try XCTUnwrap(store.workspace.browser.tabs.first { $0.id == tab.browserID })
    let host = NSHostingView(rootView: BrowserAddressField(tab: page, session: store.workspace.browser, canFocus: { true }))
    host.frame = .init(x: 0, y: 0, width: 600, height: 120)
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
    func addressField(in view: NSView) -> BrowserNativeAddressField? {
      (view as? BrowserNativeAddressField) ?? view.subviews.lazy.compactMap { addressField(in: $0) }.first
    }
    let detachedField = try XCTUnwrap(addressField(in: host))
    XCTAssertNil(detachedField.window); XCTAssertNil(host.window)
    let window = KeyWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.contentView = nil; window.close() }
    window.contentView = host
    try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
    let field = try XCTUnwrap(store.workspace.browser.addressField)
    let editor = try XCTUnwrap(field.currentEditor())
    XCTAssertTrue(window.firstResponder === editor); XCTAssertFalse(window.isVisible)
  }

  func testDelayedAddressAttachmentRejectsStaleAndBlockedRequests() async throws {
    for stale in [true, false] {
      let (store, _) = try fixture(); defer { store.workspace.browser.shutdown() }
      let tab = try browser(store, mode: .full)
      let page = try XCTUnwrap(store.workspace.browser.tabs.first { $0.id == tab.browserID })
      let host = NSHostingView(rootView: BrowserAddressField(tab: page, session: store.workspace.browser, canFocus: { stale }))
      host.frame = .init(x: 0, y: 0, width: 600, height: 120); host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(80))
      if stale { store.newBrowserTab() }
      let window = KeyWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; defer { window.contentView = nil; window.close() }
      window.contentView = host
      try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
      XCTAssertFalse(window.firstResponder is NSTextView)
      XCTAssertFalse(window.isVisible)
    }
  }

  func testCompletedAddressRequestDoesNotStealFocusOnReattachment() async throws {
    let (store, _) = try fixture(); defer { store.workspace.browser.shutdown() }
    let tab = try browser(store, mode: .full)
    let page = try XCTUnwrap(store.workspace.browser.tabs.first { $0.id == tab.browserID })
    let host = NSHostingView(rootView: BrowserAddressField(tab: page, session: store.workspace.browser, canFocus: { true }))
    let container = NSView(frame: .init(x: 0, y: 0, width: 600, height: 200))
    host.frame = .init(x: 0, y: 80, width: 600, height: 120); container.addSubview(host)
    let other = NSTextView(frame: .init(x: 0, y: 0, width: 600, height: 80)); container.addSubview(other)
    let window = KeyWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.contentView = nil; window.close() }
    window.contentView = container; host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    let editor = try XCTUnwrap(store.workspace.browser.addressField?.currentEditor())
    XCTAssertTrue(window.firstResponder === editor)
    XCTAssertTrue(window.makeFirstResponder(other))
    host.removeFromSuperview(); container.addSubview(host)
    try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
    XCTAssertTrue(window.firstResponder === other)
  }

  func testBrowserContentFocusSurvivesDelayedNativeAttachment() async throws {
    let (store, _) = try fixture(); defer { store.workspace.browser.shutdown() }
    let tab = try browser(store, mode: .full)
    let page = try XCTUnwrap(store.workspace.browser.tabs.first { $0.id == tab.browserID })
    store.workspace.browser.focusContent(page.id)
    let host = NSHostingView(rootView: BrowserHost(tab: page, session: store.workspace.browser, canFocus: { true }))
    host.frame = .init(x: 0, y: 0, width: 600, height: 200); host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertNil(page.view.window)
    let window = KeyWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.contentView = nil; window.close() }
    window.contentView = host; host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(page.view.window === window); XCTAssertTrue(window.firstResponder === page.view)
    XCTAssertFalse(window.isVisible)
  }

  func testActualTransferRemountsRecentViewThenSameMovedViewInTargetForBothLayouts() async throws {
    for mode in [WorkspaceContentLayoutMode.full, .split] {
      let (store, _) = try fixture(); defer { store.workspace.browser.shutdown() }
      let first = try browser(store, mode: mode); _ = try browser(store, mode: mode)
      let moved = try browser(store, mode: mode); _ = try browser(store, mode: mode)
      store.activateWorkspaceTab(first.id); store.activateWorkspaceTab(moved.id)
      let sourcePage = try XCTUnwrap(store.workspace.browser.tabs.first { $0.id == first.browserID })
      let movedPage = try XCTUnwrap(store.workspace.browser.tabs.first { $0.id == moved.browserID })
      let window = KeyWindow(contentRect: .init(x: 0, y: 0, width: 1200, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; defer { window.contentView = nil; window.close() }
      let host = NSHostingView(rootView: AppContentView(store: store)); window.contentView = host
      try await Task.sleep(for: .milliseconds(220)); host.layoutSubtreeIfNeeded()
      XCTAssertTrue(movedPage.view.window === window)
      XCTAssertEqual(store.moveWorkspaceTab(moved.id, toOwner: "b"), moved.id)
      try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded()
      XCTAssertTrue(sourcePage.view.window === window); XCTAssertNil(movedPage.view.window)
      XCTAssertTrue(try XCTUnwrap(store.workspace.browser.addressField?.currentEditor(), "mode=\(mode) target=\(store.workspace.browser.addressFocusTarget?.uuidString ?? "nil") selected=\(store.workspace.browser.selection?.uuidString ?? "nil") mounted=\(store.workspace.browser.addressField?.window === window) responder=\(String(describing: window.firstResponder))") === window.firstResponder)
      store.applyTaskSelection(store.library.tasks[1]); store.activateWorkspaceTab(moved.id)
      try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded()
      XCTAssertTrue(movedPage.view.window === window, "target mode=\(mode) active=\(String(describing: store.activeWorkspaceTabID)) right=\(String(describing: store.activeRightWorkspaceTabID)) inspector=\(store.showingInspector) shows=\(store.showsWorkspaceInspector) browser=\(store.workspace.browser.selection?.uuidString ?? "nil")")
      XCTAssertNil(sourcePage.view.window)
      XCTAssertEqual(store.focusedWorkspaceContentTab?.id, moved.id)
      XCTAssertTrue(try XCTUnwrap(store.workspace.browser.addressField?.currentEditor(), "mode=\(mode) target=\(store.workspace.browser.addressFocusTarget?.uuidString ?? "nil") selected=\(store.workspace.browser.selection?.uuidString ?? "nil") mounted=\(store.workspace.browser.addressField?.window === window) responder=\(String(describing: window.firstResponder))") === window.firstResponder)
      XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode, mode); XCTAssertFalse(window.isVisible)
    }
  }

  func testActualTransferWhileChatFocusedKeepsComposerResponderForBothLayouts() async throws {
    for mode in [WorkspaceContentLayoutMode.full, .split] {
      let (store, _) = try fixture(); defer { store.workspace.browser.shutdown() }
      let first = try browser(store, mode: mode), moved = try browser(store, mode: mode)
      store.activateWorkspaceTab(first.id); store.activateWorkspaceTab(moved.id); store.activateChatTab()
      let window = KeyWindow(contentRect: .init(x: 0, y: 0, width: 1200, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; defer { window.contentView = nil; window.close() }
      let host = NSHostingView(rootView: AppContentView(store: store)); window.contentView = host
      try await Task.sleep(for: .milliseconds(220)); host.layoutSubtreeIfNeeded()
      let editor = try XCTUnwrap(composer(in: host)); XCTAssertTrue(window.makeFirstResponder(editor))
      try await Task.sleep(for: .milliseconds(50))
      let address = store.workspace.browser.addressFocus, content = store.workspace.browser.contentFocus
      XCTAssertEqual(store.moveWorkspaceTab(moved.id, toOwner: "b"), moved.id)
      try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
      XCTAssertTrue(window.firstResponder === editor); XCTAssertNil(store.focusedWorkspaceContentTab)
      XCTAssertNil(store.activeWorkspaceContentTab)
      XCTAssertEqual(store.workspace.browser.addressFocus, address); XCTAssertEqual(store.workspace.browser.contentFocus, content)
      if mode == .split { XCTAssertEqual(store.activeRightWorkspaceContentTab, first) }
      XCTAssertFalse(window.isVisible)
    }
  }
}
