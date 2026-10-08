import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class NumericContentNavigationTests: XCTestCase {
  private final class KeyWindow: NSWindow { override var isKeyWindow: Bool { true } }
  private func sendNumber(_ number: Int, in window: NSWindow) throws {
    let codes: [Int: UInt16] = [1: 18, 2: 19, 3: 20]
    NSApplication.shared.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown,
      location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
      context: nil, characters: String(number), charactersIgnoringModifiers: String(number),
      isARepeat: false, keyCode: try XCTUnwrap(codes[number]))))
  }
  private struct Reference: Decodable {
    struct Selection: Decodable {
      let mode: WorkspaceContentLayoutMode
      let direction: String
      let ids: [String]
      let current: String?
      let index: Int
      let handled: Bool
      let selected: [String]
    }
    let selections: [Selection]
  }
  private func reference() throws -> Reference {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "numeric_content_navigation_reference_695",
      withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
  }
  private func fixture() throws -> (WorkspaceStore, URL) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("data"))
    store.libraryLoaded = true; store.scopeLoaded = true
    store.library.tasks = [.init(id: "a", project: root.path, title: "a", runIDs: [])]
    store.applyTaskSelection(store.library.tasks[0])
    return (store, root)
  }

  func testMainSplitNumbersSelectContentWithoutIncludingChatBottomDetachedOrOtherTask() throws {
    let (store, _) = try fixture()
    let first = WorkspaceContentTab.sources(owner: "a")
    let bottom = WorkspaceContentTab.backgroundTerminal(UUID(), owner: "a")
    let detached = WorkspaceContentTab.subagents(owner: "a")
    store.workspaceTabs = [first, bottom, detached, .sources(owner: "other")]
    store.workspaceTabPlacements[bottom.id] = .bottom
    store.workspaceTabPlacements[detached.id] = .detached
    store.workspaceContentLayoutMode = .split
    store.activateChatTab()
    store.executeCommand("focus-tab-1")
    XCTAssertEqual(store.focusedWorkspaceContentTab, first)
    XCTAssertNil(store.activeWorkspaceContentTab)
    XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode, .split)
    XCTAssertTrue(store.commandEnabled("focus-tab-1"))
    XCTAssertFalse(store.commandEnabled("focus-tab-2"))
    store.focusWorkspaceTab(at: 1)
    XCTAssertEqual(store.focusedWorkspaceContentTab, first)
    store.workspaceTabs = []
    XCTAssertFalse(store.commandEnabled("focus-tab-1"))
  }

  func testTaskFullNumbersExcludeBottomAndInvalidSlotDoesNotStealFocus() throws {
    let (store, _) = try fixture()
    let resources = TaskWindowResources(); resources.prepare("a", store: store)
    defer { resources.shutdown() }
    let tabs = try XCTUnwrap(resources.tasks["a"])
    tabs.openSources()
    let first = try XCTUnwrap(tabs.selected(.left))
    tabs.newTerminal(in: .bottom)
    tabs.activate(first.id)
    tabs.focusSlot(3)
    XCTAssertEqual(tabs.focused, first)
    tabs.contentLayoutMode = .split
    tabs.activate(nil)
    tabs.focusSlot(1)
    XCTAssertEqual(tabs.focused, first)
    XCTAssertEqual(tabs.effectiveContentLayoutMode, .split)
    XCTAssertTrue(tabs.chatVisible)
    XCTAssertTrue(tabs.commandEnabled("focus-tab-1"))
    XCTAssertFalse(tabs.commandEnabled("focus-tab-2"))
    XCTAssertFalse(tabs.perform("focus-tab-2"))
    XCTAssertEqual(tabs.focused, first)
  }

  func testMainMatchesActualNumericReferenceAcrossModesDirectionsEmptyAndExactBounds() throws {
    let reference = try reference()
    XCTAssertEqual(reference.selections.count, 336)
    for sample in reference.selections {
      let (store, _) = try fixture()
      store.workspaceTabs = sample.ids.map { .file($0, owner: "a") }
      for (index, tab) in store.workspaceTabs.enumerated() where index % 2 == 1 {
        store.workspaceTabPlacements[tab.id] = .right
      }
      store.workspaceContentLayoutMode = sample.mode
      store.workspaceContentRightToLeft = sample.direction == "rtl"
      store.activateWorkspaceTab(sample.current.map { WorkspaceContentTab.file($0, owner: "a").id })
      XCTAssertEqual(store.focusWorkspaceTab(at: sample.index), sample.handled, "\(sample)")
      let expected = sample.selected.isEmpty ? sample.current : sample.selected.first.flatMap { $0 == "chat" ? nil : $0 }
      XCTAssertEqual(store.focusedWorkspaceContentTab?.id,
        expected.map { WorkspaceContentTab.file($0, owner: "a").id }, "\(sample)")
      XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode, sample.mode)
      if sample.mode == .split { XCTAssertNil(store.activeWorkspaceContentTab) }
      if (0..<9).contains(sample.index) {
        XCTAssertEqual(store.commandEnabled("focus-tab-\(sample.index + 1)"), sample.handled)
      }
    }
  }

  func testTaskMatchesActualNumericReferenceAcrossModesDirectionsEmptyAndExactBounds() throws {
    for sample in try reference().selections {
      let (store, root) = try fixture()
      for path in sample.ids { try Data(path.utf8).write(to: root.appendingPathComponent(path)) }
      let resources = TaskWindowResources(); resources.prepare("a", store: store)
      defer { resources.shutdown() }
      let tabs = try XCTUnwrap(resources.tasks["a"])
      let saved = sample.ids.enumerated().map { index, path in
        SavedWorkspaceTab(id: WorkspaceContentTab.file(path, owner: "a").id, kind: .file,
          placement: index % 2 == 0 ? .left : .right, filePath: path)
      }
      let current = sample.current.map { WorkspaceContentTab.file($0, owner: "a").id }
      tabs.restoreLayout(.init(project: tabs.panels.workspace.root?.path,
        content: .init(tabs: saved, active: sample.mode == .full ? current : nil,
          right: sample.mode == .split ? current : nil, bottom: nil, focused: current,
          showingInspector: sample.mode == .split && current != nil, showingTerminal: false,
          showingTabs: true, side: .left, reviewScope: .unstaged, contentLayoutMode: sample.mode),
        panelSizes: tabs.panels.panelSizes, showingFiles: false))
      tabs.contentRightToLeft = sample.direction == "rtl"
      XCTAssertEqual(tabs.focusSlot(sample.index + 1), sample.handled, "\(sample)")
      let expected = sample.selected.isEmpty ? sample.current : sample.selected.first.flatMap { $0 == "chat" ? nil : $0 }
      XCTAssertEqual(tabs.focused?.id, expected.map { WorkspaceContentTab.file($0, owner: "a").id }, "\(sample)")
      XCTAssertEqual(tabs.effectiveContentLayoutMode, sample.mode)
      if sample.mode == .split { XCTAssertTrue(tabs.chatVisible) }
      if (0..<9).contains(sample.index) {
        XCTAssertEqual(tabs.commandEnabled("focus-tab-\(sample.index + 1)"), sample.handled)
      }
      XCTAssertEqual(store.selectedTask?.id, "a")
      XCTAssertTrue(store.workspaceTabs.isEmpty)
    }
  }

  func testNumericSelectionRevealsHiddenSplitContentAndUsesCurrentReorderedPool() throws {
    let (store, _) = try fixture()
    let first = WorkspaceContentTab.sources(owner: "a"), second = WorkspaceContentTab.subagents(owner: "a")
    store.workspaceTabs = [first, second]; store.workspaceContentLayoutMode = .split
    store.showingInspector = false; store.activateChatTab()
    XCTAssertTrue(store.handleWorkspaceShortcut(ShortcutBinding("⌘2")))
    XCTAssertTrue(store.showsWorkspaceInspector)
    XCTAssertEqual(store.focusedWorkspaceContentTab, second)
    XCTAssertTrue(store.reorderWorkspaceTab(second.id, relativeTo: first.id, after: false))
    XCTAssertTrue(store.focusWorkspaceTab(at: 0))
    XCTAssertEqual(store.focusedWorkspaceContentTab, second)
    let resources = TaskWindowResources(); resources.prepare("a", store: store)
    defer { resources.shutdown() }
    let tabs = try XCTUnwrap(resources.tasks["a"])
    tabs.openSources(); XCTAssertTrue(tabs.openSubagents())
    tabs.showingRight = false; tabs.activate(nil)
    XCTAssertTrue(tabs.perform("focus-tab-2"))
    XCTAssertTrue(tabs.showsContentSidePanel)
    XCTAssertEqual(tabs.focused, second)
    XCTAssertTrue(tabs.reorder(second.id, relativeTo: first.id, after: false))
    XCTAssertTrue(tabs.perform("focus-tab-1"))
    XCTAssertEqual(tabs.focused, second)
  }

  func testEmptyFullChatHasOneNumericCommandAndSplitHasNoneInBothWindows() throws {
    let (store, _) = try fixture()
    let resources = TaskWindowResources(); resources.prepare("a", store: store)
    defer { resources.shutdown() }
    let tabs = try XCTUnwrap(resources.tasks["a"])
    for mode in [WorkspaceContentLayoutMode.full, .split] {
      store.workspaceContentLayoutMode = mode; tabs.contentLayoutMode = mode
      XCTAssertEqual(store.commandEnabled("focus-tab-1"), mode == .full)
      XCTAssertEqual(tabs.commandEnabled("focus-tab-1"), mode == .full)
      XCTAssertFalse(store.commandEnabled("focus-tab-2"))
      XCTAssertFalse(tabs.commandEnabled("focus-tab-2"))
      for invalid in ["focus-tab-0", "focus-tab-10", "focus-tab-nan"] {
        XCTAssertFalse(store.commandEnabled(invalid)); XCTAssertFalse(tabs.commandEnabled(invalid))
      }
    }
  }

  func testNinthCommandIsExactAndTenthCannotExecuteEvenWhenContentExists() throws {
    let (store, _) = try fixture()
    store.workspaceTabs = (1...11).map { .file("file-\($0)", owner: "a") }
    for mode in [WorkspaceContentLayoutMode.full, .split] {
      store.workspaceContentLayoutMode = mode
      store.executeCommand("focus-tab-9")
      let expected = WorkspaceContentTab.file(mode == .full ? "file-8" : "file-9", owner: "a")
      XCTAssertEqual(store.focusedWorkspaceContentTab, expected)
      store.executeCommand("focus-tab-10")
      XCTAssertEqual(store.focusedWorkspaceContentTab, expected)
      XCTAssertFalse(store.commandEnabled("focus-tab-10"))
    }
  }

  func testActualHiddenViewsPublishRTLAndRestoreLTRWithoutPersistingDirection() async throws {
    let (store, _) = try fixture()
    defer { store.workspace.browser.shutdown() }
    store.newBrowserTab(); let first = try XCTUnwrap(store.activeWorkspaceContentTab)
    store.newBrowserTab(); let second = try XCTUnwrap(store.activeWorkspaceContentTab)
    store.activateWorkspaceTab(first.id)
    let window = KeyWindow(contentRect: .init(x: 0, y: 0, width: 1200, height: 720),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.contentView = nil; window.close() }
    let host = NSHostingView(rootView: AppContentView(store: store).environment(\.layoutDirection, .rightToLeft))
    window.contentView = host
    try await Task.sleep(for: .milliseconds(220)); host.layoutSubtreeIfNeeded()
    XCTAssertTrue(store.workspaceContentRightToLeft)
    try sendNumber(1, in: window)
    XCTAssertEqual(store.activeWorkspaceContentTab, second)
    let page = try XCTUnwrap(store.workspace.browser.tabs.first { $0.id == second.browserID })
    try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
    XCTAssertTrue(page.view.window === window)
    try sendNumber(3, in: window)
    XCTAssertNil(store.activeWorkspaceContentTab)
    host.rootView = AppContentView(store: store).environment(\.layoutDirection, .leftToRight)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertFalse(store.workspaceContentRightToLeft)
    try sendNumber(2, in: window)
    XCTAssertEqual(store.activeWorkspaceContentTab, first)
    XCTAssertFalse(window.isVisible)

    let resources = TaskWindowResources(); resources.prepare("a", store: store)
    defer { resources.shutdown() }
    let tabs = try XCTUnwrap(resources.tasks["a"])
    tabs.newBrowser(); let taskFirst = try XCTUnwrap(tabs.selected(.left))
    tabs.newBrowser(); let taskSecond = try XCTUnwrap(tabs.selected(.left)); tabs.activate(taskFirst.id)
    let taskWindow = KeyWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 720),
      styleMask: [.titled], backing: .buffered, defer: false)
    taskWindow.isReleasedWhenClosed = false
    defer { taskWindow.contentView = nil; taskWindow.close() }
    let view = TaskWindowView(store: store, taskID: "a", tabs: tabs, resources: resources,
      renameHistory: TaskRenameHistory(), onNavigate: { _ in }, canGoBack: false,
      canGoForward: false, onMove: { _ in })
    let taskHost = NSHostingView(rootView: view.environment(\.layoutDirection, .rightToLeft))
    taskWindow.contentView = taskHost
    try await Task.sleep(for: .milliseconds(220)); taskHost.layoutSubtreeIfNeeded()
    XCTAssertTrue(tabs.contentRightToLeft)
    try sendNumber(1, in: taskWindow)
    XCTAssertEqual(tabs.focused, taskSecond)
    try await Task.sleep(for: .milliseconds(100)); taskHost.layoutSubtreeIfNeeded()
    XCTAssertTrue(try XCTUnwrap(tabs.browser.session.tabs.first { $0.id == taskSecond.browserID }).view.window === taskWindow)
    try sendNumber(3, in: taskWindow)
    XCTAssertNil(tabs.focused)
    taskHost.rootView = view.environment(\.layoutDirection, .leftToRight)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertFalse(tabs.contentRightToLeft)
    try sendNumber(2, in: taskWindow)
    XCTAssertEqual(tabs.focused, taskFirst)
    XCTAssertFalse(taskWindow.isVisible)
    XCTAssertFalse(String(decoding: try JSONEncoder().encode(tabs.layoutSnapshot), as: UTF8.self).contains("RightToLeft"))
  }
}
