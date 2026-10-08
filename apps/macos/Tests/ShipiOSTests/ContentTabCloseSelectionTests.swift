import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class ContentTabCloseSelectionTests: XCTestCase {
  private final class KeyWindow: NSWindow { override var isKeyWindow: Bool { true } }
  private func sendClose(in window: NSWindow) throws {
    NSApplication.shared.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown,
      location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
      context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)))
  }
  private func composer(in view: NSView) -> ComposerNativeTextView? {
    (view as? ComposerNativeTextView) ?? view.subviews.lazy.compactMap { self.composer(in: $0) }.first
  }
  private struct Reference: Decodable {
    struct History: Decodable {
      struct Entry: Decodable { let generation: Int; let openerTabId: String }
      let active: Bool; let generation: Int; let lastSelectedTabId: String?
      let tabs: [String: Entry]
    }
    struct Step: Decodable {
      let action: String; let id: String?; let opener: String?; let background: Bool?
      let target: String?; let after: Bool?; let ids: [String]; let selected: String?; let history: History
    }
    struct Trace: Decodable { let name: String; let steps: [Step] }
    struct Sibling: Decodable { let ids: [String]; let state: History; let closing: String; let next: String? }
    let traces: [Trace]; let siblingCases: [Sibling]
  }
  private func reference() throws -> Reference {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "content_close_reference_696",
      withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
  }
  private func assertHistory(_ history: ContentTabCloseHistory, _ expected: Reference.History,
    _ label: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(history.active, expected.active, label, file: file, line: line)
    XCTAssertEqual(history.generation, expected.generation, label, file: file, line: line)
    XCTAssertEqual(history.lastSelectedTabID, expected.lastSelectedTabId, label, file: file, line: line)
    XCTAssertEqual(history.tabs, expected.tabs.mapValues {
      ContentTabCloseHistory.Entry(generation: $0.generation, openerTabID: $0.openerTabId)
    }, label, file: file, line: line)
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

  func testMainFullCloseSelectsRightNeighborAcrossContentKinds() throws {
    let (store, _) = try fixture()
    let first = WorkspaceContentTab.sources(owner: "a"), second = WorkspaceContentTab.subagents(owner: "a")
    let third = WorkspaceContentTab.file("third", owner: "a")
    store.workspaceTabs = [first, second, third]
    store.workspaceContentLayoutMode = .full
    store.activateWorkspaceTab(second.id)
    store.closeWorkspaceTab(second.id)
    XCTAssertEqual(store.activeWorkspaceContentTab, third)
    XCTAssertEqual(store.focusedWorkspaceContentTab, third)
  }

  func testTaskFullCloseSelectsRightNeighborRatherThanChat() throws {
    let (store, root) = try fixture()
    for name in ["first", "second", "third"] { try Data().write(to: root.appendingPathComponent(name)) }
    let resources = TaskWindowResources(); resources.prepare("a", store: store); defer { resources.shutdown() }
    let tabs = try XCTUnwrap(resources.tasks["a"])
    for name in ["first", "second", "third"] { XCTAssertTrue(tabs.openFile(name)) }
    let second = WorkspaceContentTab.file("second", owner: "a"), third = WorkspaceContentTab.file("third", owner: "a")
    tabs.activate(second.id); tabs.close(second.id)
    XCTAssertEqual(tabs.selected(.left), third)
    XCTAssertEqual(tabs.focused, third)
  }

  func testMainBrowserChildCloseReturnsToExplicitOpenerInsteadOfUnrelatedBrowser() throws {
    let (store, _) = try fixture(); defer { store.workspace.browser.shutdown() }
    store.newBrowserTab(); let opener = try XCTUnwrap(store.activeWorkspaceContentTab)
    store.newBrowserTab(); let unrelated = try XCTUnwrap(store.activeWorkspaceContentTab)
    let child = try XCTUnwrap(store.newBrowserChild(from: try XCTUnwrap(opener.browserID)))
    store.closeWorkspaceTab(WorkspaceContentTab.browser(child.id, owner: "a").id)
    XCTAssertEqual(store.activeWorkspaceContentTab, opener)
    XCTAssertNotEqual(store.activeWorkspaceContentTab, unrelated)
    XCTAssertEqual(store.workspace.browser.selection, opener.browserID)
  }

  func testTaskBrowserChildCloseReturnsToExplicitOpener() throws {
    let (store, _) = try fixture()
    let resources = TaskWindowResources(); resources.prepare("a", store: store); defer { resources.shutdown() }
    let tabs = try XCTUnwrap(resources.tasks["a"])
    tabs.newBrowser(); let opener = try XCTUnwrap(tabs.selected(.left))
    tabs.newBrowser()
    let child = try XCTUnwrap(tabs.browser.session.newChildTab(from: try XCTUnwrap(opener.browserID)))
    tabs.close(WorkspaceContentTab.browser(child.id, owner: "a").id)
    XCTAssertEqual(tabs.selected(.left), opener)
    XCTAssertEqual(tabs.browser.session.selection, opener.browserID)
  }

  func testControllerMatchesAllActualReferenceTracesIncludingBackgroundAndInvalidation() throws {
    let reference = try reference()
    XCTAssertEqual(reference.traces.count, 24)
    for trace in reference.traces {
      var controller = ContentTabCloseController(), ids: [String] = []
      for (index, step) in trace.steps.enumerated() {
        let label = "\(trace.name), step \(index): \(step.action)"
        switch step.action {
        case "open":
          let id = try XCTUnwrap(step.id), fresh = !ids.contains(id)
          if fresh {
            let insertion = step.opener.flatMap { ids.firstIndex(of: $0) }.map { $0 + 1 } ?? ids.count
            ids.insert(id, at: insertion)
            if let opener = step.opener, ids.contains(opener) {
              controller.history.opened(id, by: opener, background: step.background == true)
            }
          }
          if step.background != true { controller.select(id, in: ids) }
        case "select": controller.select(step.id, in: ids)
        case "reorder":
          let id = try XCTUnwrap(step.id), target = try XCTUnwrap(step.target)
          ids.remove(at: try XCTUnwrap(ids.firstIndex(of: id)))
          ids.insert(id, at: try XCTUnwrap(ids.firstIndex(of: target)) + (step.after == true ? 1 : 0))
          controller.history.moved(id)
        case "close":
          let id = try XCTUnwrap(step.id)
          _ = controller.close(id, in: ids); ids.removeAll { $0 == id }
        default: XCTFail("Unknown reference action \(step.action)")
        }
        XCTAssertEqual(ids, step.ids, label)
        XCTAssertEqual(controller.selectedID, step.selected, label)
        assertHistory(controller.history, step.history, label)
      }
    }
  }

  func testMissingOpenerUsesReferenceRelatedSiblingBeforeOrdinaryNeighbor() throws {
    let reference = try reference()
    XCTAssertEqual(reference.siblingCases.count, 4)
    for item in reference.siblingCases {
      var history = ContentTabCloseHistory()
      history.selected(nil, in: []); history.selected(nil, in: [])
      history.opened("b", by: "missing", background: true)
      history.opened("c", by: "missing", background: true)
      history.selected("b", in: item.ids)
      assertHistory(history, item.state, item.ids.joined(separator: ","))
      XCTAssertEqual(history.fallback(closing: item.closing, in: item.ids), item.next)
    }
  }

  private func foregroundTraces() throws -> [Reference.Trace] {
    try reference().traces.filter { trace in
      !trace.steps.contains { $0.background == true || ($0.action == "select" && $0.id == nil) }
    }
  }
  private func mainTraces(mode: WorkspaceContentLayoutMode) throws {
    for trace in try foregroundTraces() {
      try autoreleasepool {
        let (store, _) = try fixture(); defer { store.workspace.browser.shutdown() }
        store.workspaceContentLayoutMode = mode
        var mapping: [String: WorkspaceContentTab] = [:]
        for (index, step) in trace.steps.enumerated() {
          let name = try XCTUnwrap(step.id), label = "main \(mode) \(trace.name), step \(index)"
          switch step.action {
          case "open":
            if let opener = step.opener {
              let page = try XCTUnwrap(store.newBrowserChild(from: try XCTUnwrap(mapping[opener]?.browserID)))
              mapping[name] = .browser(page.id, owner: "a")
            } else {
              store.newBrowserTab(in: mode == .full ? .left : .right)
              mapping[name] = try XCTUnwrap(mode == .full ? store.activeWorkspaceContentTab : store.activeRightWorkspaceContentTab)
            }
          case "select": store.activateWorkspaceTab(try XCTUnwrap(mapping[name]?.id))
          case "reorder": XCTAssertTrue(store.reorderWorkspaceTab(try XCTUnwrap(mapping[name]?.id),
            relativeTo: try XCTUnwrap(mapping[try XCTUnwrap(step.target)]?.id), after: step.after == true), label)
          case "close": store.closeWorkspaceTab(mapping[name]?.id ?? "missing-reference-tab")
          default: XCTFail(label)
          }
          XCTAssertEqual(store.workspacePrimaryContentTabs.map(\.id), try step.ids.map { try XCTUnwrap(mapping[$0]?.id) }, label)
          let selected = step.selected.flatMap { mapping[$0] }
          XCTAssertEqual(mode == .full ? store.activeWorkspaceContentTab : store.activeRightWorkspaceContentTab, selected, label)
          XCTAssertEqual(store.focusedWorkspaceContentTab, selected, label)
          XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode, mode, label)
        }
      }
    }
  }
  private func taskTraces(mode: WorkspaceContentLayoutMode) throws {
    for trace in try foregroundTraces() {
      try autoreleasepool {
        let (store, _) = try fixture()
        let resources = TaskWindowResources(); resources.prepare("a", store: store); defer { resources.shutdown() }
        let tabs = try XCTUnwrap(resources.tasks["a"]); tabs.contentLayoutMode = mode
        var mapping: [String: WorkspaceContentTab] = [:]
        for (index, step) in trace.steps.enumerated() {
          let name = try XCTUnwrap(step.id), label = "task \(mode) \(trace.name), step \(index)"
          switch step.action {
          case "open":
            if let opener = step.opener {
              let page = try XCTUnwrap(tabs.browser.session.newChildTab(from: try XCTUnwrap(mapping[opener]?.browserID)))
              mapping[name] = .browser(page.id, owner: "a")
            } else {
              tabs.newBrowser(in: mode == .full ? .left : .right)
              mapping[name] = try XCTUnwrap(tabs.selected(mode == .full ? .left : .right))
            }
          case "select": tabs.activate(try XCTUnwrap(mapping[name]?.id))
          case "reorder": XCTAssertTrue(tabs.reorder(try XCTUnwrap(mapping[name]?.id),
            relativeTo: try XCTUnwrap(mapping[try XCTUnwrap(step.target)]?.id), after: step.after == true), label)
          case "close": tabs.close(mapping[name]?.id ?? "missing-reference-tab")
          default: XCTFail(label)
          }
          XCTAssertEqual(tabs.primaryContentTabs.map(\.id), try step.ids.map { try XCTUnwrap(mapping[$0]?.id) }, label)
          let selected = step.selected.flatMap { mapping[$0] }
          XCTAssertEqual(tabs.selected(mode == .full ? .left : .right), selected, label)
          XCTAssertEqual(tabs.focused, selected, label)
          XCTAssertEqual(tabs.effectiveContentLayoutMode, mode, label)
        }
      }
    }
  }
  func testMainFullForegroundControllerTraces() throws { try mainTraces(mode: .full) }
  func testMainSplitForegroundControllerTraces() throws { try mainTraces(mode: .split) }
  func testTaskFullForegroundControllerTraces() throws { try taskTraces(mode: .full) }
  func testTaskSplitForegroundControllerTraces() throws { try taskTraces(mode: .split) }

  func testMainChatAndLayoutChangesPreserveOpenerWithoutStealingComposerFocus() throws {
    for mode in [WorkspaceContentLayoutMode.full, .split] {
      let (store, _) = try fixture(); defer { store.workspace.browser.shutdown() }
      store.newBrowserTab(); let opener = try XCTUnwrap(store.activeWorkspaceContentTab)
      store.newBrowserTab()
      let child = try XCTUnwrap(store.newBrowserChild(from: try XCTUnwrap(opener.browserID)))
      let childID = WorkspaceContentTab.browser(child.id, owner: "a").id
      store.moveWorkspaceTab(childID, to: mode == .full ? .left : .right)
      store.activateChatTab()
      let address = store.workspace.browser.addressFocus, content = store.workspace.browser.contentFocus, composer = store.focusComposer
      store.closeWorkspaceTab(childID)
      XCTAssertNil(store.activeWorkspaceContentTab)
      XCTAssertNil(store.focusedWorkspaceContentTab)
      XCTAssertEqual(store.lastWorkspaceContentTabID, opener.id)
      XCTAssertEqual(store.workspace.browser.selection, opener.browserID)
      if mode == .split { XCTAssertEqual(store.activeRightWorkspaceContentTab, opener) }
      XCTAssertEqual(store.workspace.browser.addressFocus, address)
      XCTAssertEqual(store.workspace.browser.contentFocus, content)
      XCTAssertEqual(store.focusComposer, composer)
      XCTAssertEqual(store.effectiveWorkspaceContentLayoutMode, mode)
    }
  }

  func testTaskChatAndLayoutChangesPreserveOpenerWithoutStealingComposerFocus() throws {
    for mode in [WorkspaceContentLayoutMode.full, .split] {
      let (store, _) = try fixture()
      let resources = TaskWindowResources(); resources.prepare("a", store: store); defer { resources.shutdown() }
      let tabs = try XCTUnwrap(resources.tasks["a"])
      tabs.newBrowser(); let opener = try XCTUnwrap(tabs.selected(.left)); tabs.newBrowser()
      let child = try XCTUnwrap(tabs.browser.session.newChildTab(from: try XCTUnwrap(opener.browserID)))
      let childID = WorkspaceContentTab.browser(child.id, owner: "a").id
      tabs.move(childID, to: mode == .full ? .left : .right); tabs.activate(nil)
      let address = tabs.browser.session.addressFocus, content = tabs.browser.session.contentFocus, composer = tabs.chatFocus
      tabs.close(childID)
      XCTAssertTrue(tabs.chatVisible); XCTAssertNil(tabs.focused)
      XCTAssertEqual(tabs.lastContentForCommand, opener.id)
      XCTAssertEqual(tabs.browser.session.selection, opener.browserID)
      if mode == .split { XCTAssertEqual(tabs.selected(.right), opener) }
      XCTAssertEqual(tabs.browser.session.addressFocus, address)
      XCTAssertEqual(tabs.browser.session.contentFocus, content)
      XCTAssertEqual(tabs.chatFocus, composer)
      XCTAssertEqual(tabs.effectiveContentLayoutMode, mode)
    }
  }

  func testInactiveTaskCloseRepairsSavedSelectionWithoutChangingCurrentTaskOrFocus() throws {
    let (store, root) = try fixture(); defer { store.workspace.browser.shutdown() }
    store.newBrowserTab(); let opener = try XCTUnwrap(store.activeWorkspaceContentTab); store.newBrowserTab()
    let child = try XCTUnwrap(store.newBrowserChild(from: try XCTUnwrap(opener.browserID)))
    let childID = WorkspaceContentTab.browser(child.id, owner: "a").id
    store.captureWorkspaceTabLayout()
    let other = WorkspaceTask(id: "b", project: root.path, title: "b", runIDs: [])
    store.library.tasks.append(other); store.applyTaskSelection(other); store.newBrowserTab()
    let selected = store.focusedWorkspaceContentTab, address = store.workspace.browser.addressFocus, content = store.workspace.browser.contentFocus
    store.closeWorkspaceTab(childID)
    XCTAssertEqual(store.selection, "b"); XCTAssertEqual(store.focusedWorkspaceContentTab, selected)
    XCTAssertEqual(store.workspace.browser.selection, selected?.browserID)
    XCTAssertEqual(store.workspace.browser.addressFocus, address); XCTAssertEqual(store.workspace.browser.contentFocus, content)
    XCTAssertEqual(store.library.workspaceTabLayouts["a"]?.active, opener.id)
    XCTAssertEqual(store.library.workspaceTabLayouts["a"]?.focused, opener.id)
    XCTAssertFalse(store.library.workspaceTabLayouts["a"]?.tabs.contains { $0.id == childID } == true)
  }

  func testMainMixedCloseScopesExcludeBottomDetachedAndOtherTask() throws {
    let (store, _) = try fixture()
    let first = WorkspaceContentTab.sources(owner: "a"), last = WorkspaceContentTab.subagents(owner: "a")
    let bottom = WorkspaceContentTab.backgroundTerminal(UUID(), owner: "a"), detached = WorkspaceContentTab.file("detached", owner: "a")
    let other = WorkspaceContentTab.sources(owner: "b")
    store.workspaceTabs = [first, bottom, detached, other, last]
    store.workspaceTabPlacements[bottom.id] = .bottom; store.workspaceTabPlacements[detached.id] = .detached
    store.workspaceContentLayoutMode = .full; store.activateWorkspaceTab(first.id)
    store.closeWorkspaceTab(first.id)
    XCTAssertEqual(store.activeWorkspaceContentTab, last); XCTAssertEqual(store.focusedWorkspaceContentTab, last)
    store.closeWorkspaceTab(last.id)
    XCTAssertNil(store.activeWorkspaceContentTab); XCTAssertNil(store.focusedWorkspaceContentTab)
    XCTAssertEqual(store.workspaceTabs, [bottom, detached, other])
  }

  func testInactiveBrowserChildKeepsBesideOrderInSavedLayoutAndDoesNotSelectItself() throws {
    let (store, root) = try fixture(); defer { store.workspace.browser.shutdown() }
    store.newBrowserTab(); let opener = try XCTUnwrap(store.activeWorkspaceContentTab)
    store.newBrowserTab(); let unrelated = try XCTUnwrap(store.activeWorkspaceContentTab)
    store.captureWorkspaceTabLayout()
    let other = WorkspaceTask(id: "b", project: root.path, title: "b", runIDs: [])
    store.library.tasks.append(other); store.applyTaskSelection(other); store.newBrowserTab()
    let selected = store.focusedWorkspaceContentTab, focus = store.workspace.browser.addressFocus
    let child = try XCTUnwrap(store.newBrowserChild(from: try XCTUnwrap(opener.browserID)))
    let id = WorkspaceContentTab.browser(child.id, owner: "a").id
    XCTAssertEqual(store.workspaceTabs.filter { $0.owner == "a" }.map(\.id), [opener.id, id, unrelated.id])
    XCTAssertEqual(store.library.workspaceTabLayouts["a"]?.tabs.map(\.id), [opener.id, id, unrelated.id])
    XCTAssertEqual(store.library.workspaceTabLayouts["a"]?.active, unrelated.id)
    XCTAssertEqual(store.focusedWorkspaceContentTab, selected)
    XCTAssertEqual(store.workspace.browser.selection, selected?.browserID)
    XCTAssertEqual(store.workspace.browser.addressFocus, focus)
  }

  func testColdMainRestorationDoesNotReplayEphemeralOpenerHistory() throws {
    let (store, root) = try fixture(); defer { store.workspace.browser.shutdown() }
    store.project = root; store.workspace.setProject(root)
    store.newBrowserTab(); let opener = try XCTUnwrap(store.activeWorkspaceContentTab)
    store.newBrowserTab(); let neighbor = try XCTUnwrap(store.activeWorkspaceContentTab)
    let child = try XCTUnwrap(store.newBrowserChild(from: try XCTUnwrap(opener.browserID)))
    let id = WorkspaceContentTab.browser(child.id, owner: "a").id
    let restored = WorkspaceStore(dataRoot: root.appendingPathComponent("restored")); defer { restored.workspace.browser.shutdown() }
    restored.library = store.library; restored.library.workspaceTabLayouts["a"] = store.workspaceTabLayoutSnapshot
    restored.libraryLoaded = true; restored.scopeLoaded = true; restored.connected = true
    restored.project = root; restored.workspace.setProject(root); restored.selection = "a"
    restored.restoreWorkspaceTabLayout()
    XCTAssertEqual(restored.activeWorkspaceContentTab?.id, id)
    restored.closeWorkspaceTab(id)
    XCTAssertEqual(restored.activeWorkspaceContentTab?.id, neighbor.id)
    XCTAssertNotEqual(restored.activeWorkspaceContentTab?.id, opener.id)
  }

  func testColdTaskRestorationDoesNotReplayEphemeralOpenerHistory() throws {
    let (store, _) = try fixture()
    let resources = TaskWindowResources(); resources.prepare("a", store: store); defer { resources.shutdown() }
    let tabs = try XCTUnwrap(resources.tasks["a"])
    tabs.newBrowser(); let opener = try XCTUnwrap(tabs.selected(.left))
    tabs.newBrowser(); let neighbor = try XCTUnwrap(tabs.selected(.left))
    let child = try XCTUnwrap(tabs.browser.session.newChildTab(from: try XCTUnwrap(opener.browserID)))
    let restoredResources = TaskWindowResources(); restoredResources.prepare("a", store: store); defer { restoredResources.shutdown() }
    let restored = try XCTUnwrap(restoredResources.tasks["a"]); restored.restoreLayout(tabs.layoutSnapshot)
    let id = WorkspaceContentTab.browser(child.id, owner: "a").id
    XCTAssertEqual(restored.selected(.left)?.id, id)
    restored.close(id)
    XCTAssertEqual(restored.selected(.left)?.id, neighbor.id)
    XCTAssertNotEqual(restored.selected(.left)?.id, opener.id)
  }

  func testHiddenPaneCloseDoesNotReopenItOrRequestNativeFocusInEitherWindow() throws {
    let (store, _) = try fixture(); defer { store.workspace.browser.shutdown() }
    store.newBrowserTab(); let opener = try XCTUnwrap(store.activeWorkspaceContentTab)
    let child = try XCTUnwrap(store.newBrowserChild(from: try XCTUnwrap(opener.browserID)))
    let id = WorkspaceContentTab.browser(child.id, owner: "a").id
    store.moveWorkspaceTab(id, to: .right); store.showingInspector = false
    let address = store.workspace.browser.addressFocus, composer = store.focusComposer
    store.closeWorkspaceTab(id)
    XCTAssertFalse(store.showingInspector); XCTAssertNil(store.focusedWorkspaceContentTab)
    XCTAssertNil(store.focusedWorkspaceTabID)
    XCTAssertEqual(store.activeRightWorkspaceContentTab, opener)
    XCTAssertEqual(store.workspace.browser.addressFocus, address); XCTAssertEqual(store.focusComposer, composer)
    let resources = TaskWindowResources(); resources.prepare("a", store: store); defer { resources.shutdown() }
    let tabs = try XCTUnwrap(resources.tasks["a"])
    tabs.newBrowser(); let taskOpener = try XCTUnwrap(tabs.selected(.left))
    let taskChild = try XCTUnwrap(tabs.browser.session.newChildTab(from: try XCTUnwrap(taskOpener.browserID)))
    let taskID = WorkspaceContentTab.browser(taskChild.id, owner: "a").id
    tabs.move(taskID, to: .right); tabs.showingRight = false
    let taskAddress = tabs.browser.session.addressFocus, taskComposer = tabs.chatFocus
    tabs.close(taskID)
    XCTAssertFalse(tabs.showingRight); XCTAssertNil(tabs.focused); XCTAssertNil(tabs.focusedID)
    XCTAssertEqual(tabs.selected(.right), taskOpener)
    XCTAssertEqual(tabs.browser.session.addressFocus, taskAddress); XCTAssertEqual(tabs.chatFocus, taskComposer)
  }

  func testDetachedCloseCannotRequestMainComposerFocus() throws {
    let (store, _) = try fixture(); defer { store.workspace.browser.shutdown() }
    store.newBrowserTab(); let tab = try XCTUnwrap(store.activeWorkspaceContentTab)
    store.moveWorkspaceTab(tab.id, to: .detached)
    let composer = store.focusComposer
    store.closeWorkspaceTab(tab.id)
    XCTAssertNil(store.focusedWorkspaceTabID); XCTAssertEqual(store.focusComposer, composer)
  }

  func testBottomCloseRetainsPrimarySelectionAndSurvivingShellInBothWindows() throws {
    let (store, root) = try fixture()
    store.project = root; store.workspace.setProject(root)
    defer { store.workspace.terminals.shutdown() }
    store.workspaceTabs = [.sources(owner: "a")]
    let primary = store.workspaceTabs[0]; store.activateWorkspaceTab(primary.id)
    store.newTerminalTab(); let first = try XCTUnwrap(store.activeBottomWorkspaceContentTab)
    store.newTerminalTab(); let second = try XCTUnwrap(store.activeBottomWorkspaceContentTab)
    let survivor = try XCTUnwrap(store.terminalSession(try XCTUnwrap(first.terminalID))), pid = survivor.view.process.shellPid
    store.closeWorkspaceTab(second.id)
    XCTAssertEqual(store.activeBottomWorkspaceContentTab, first); XCTAssertEqual(store.activeWorkspaceContentTab, primary)
    XCTAssertEqual(store.focusedWorkspaceContentTab, first); XCTAssertTrue(store.showingTerminal)
    XCTAssertEqual(survivor.view.process.shellPid, pid); XCTAssertTrue(survivor.view.process.running)
    store.closeWorkspaceTab(first.id)
    XCTAssertFalse(store.showingTerminal); XCTAssertEqual(store.activeWorkspaceContentTab, primary)
    let resources = TaskWindowResources(); resources.prepare("a", store: store); defer { resources.shutdown() }
    let tabs = try XCTUnwrap(resources.tasks["a"]); tabs.openSources()
    let taskPrimary = try XCTUnwrap(tabs.selected(.left))
    tabs.newTerminal(); let taskFirst = try XCTUnwrap(tabs.selected(.bottom))
    tabs.newTerminal(); let taskSecond = try XCTUnwrap(tabs.selected(.bottom))
    let taskSurvivor = try XCTUnwrap(tabs.panels.terminals.first { $0.id == taskFirst.terminalID }), taskPID = taskSurvivor.view.process.shellPid
    tabs.close(taskSecond.id)
    XCTAssertEqual(tabs.selected(.bottom), taskFirst); XCTAssertEqual(tabs.selected(.left), taskPrimary)
    XCTAssertEqual(tabs.focused, taskFirst); XCTAssertTrue(tabs.showingBottom)
    XCTAssertEqual(taskSurvivor.view.process.shellPid, taskPID); XCTAssertTrue(taskSurvivor.view.process.running)
    tabs.close(taskFirst.id)
    XCTAssertFalse(tabs.showingBottom); XCTAssertEqual(tabs.selected(.left), taskPrimary)
  }

  private func dirtyConflict(taskWindow: Bool) async throws {
    let (store, root) = try fixture(), path = root.appendingPathComponent("file.txt")
    try "original".write(to: path, atomically: true, encoding: .utf8)
    store.project = root; store.workspace.setProject(root)
    let resources = TaskWindowResources(); defer { resources.shutdown() }
    var close: (String) -> Void, contains: (WorkspaceContentTab) -> Bool, selected: () -> WorkspaceContentTab?
    let tab: WorkspaceContentTab, next: WorkspaceContentTab
    if taskWindow {
      resources.prepare("a", store: store); let tabs = try XCTUnwrap(resources.tasks["a"])
      XCTAssertTrue(tabs.openFile("file.txt")); tab = try XCTUnwrap(tabs.selected(.left))
      tabs.openSources(); next = try XCTUnwrap(tabs.selected(.left)); tabs.activate(tab.id)
      close = tabs.close; contains = { tabs.tabs.contains($0) }; selected = { tabs.selected(.left) }
    } else {
      XCTAssertTrue(store.openFileTab("file.txt")); tab = try XCTUnwrap(store.activeWorkspaceContentTab)
      next = .sources(owner: "a"); store.workspaceTabs.append(next); store.activateWorkspaceTab(tab.id)
      close = store.closeWorkspaceTab; contains = { store.workspaceTabs.contains($0) }; selected = { store.activeWorkspaceContentTab }
    }
    let editor = store.fileTabWorkspace(tab); editor.root = root; await editor.openFile("file.txt")
    editor.beginEditingSelectedFile(); editor.editSelectedFile("local draft")
    try "external".write(to: path, atomically: true, encoding: .utf8)
    close(tab.id); close(tab.id)
    for _ in 0..<80 where editor.selectedFileEditor?.changedOnDisk == nil { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertEqual(editor.selectedFileEditor?.changedOnDisk, "external")
    XCTAssertTrue(contains(tab)); XCTAssertEqual(selected(), tab)
    XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "external")
    close(tab.id)
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertTrue(contains(tab)); XCTAssertEqual(selected(), tab)
    let saved = await editor.useLocalFileEditsAfterConflict(); XCTAssertTrue(saved)
    close(tab.id)
    XCTAssertFalse(contains(tab)); XCTAssertEqual(selected(), next)
    XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "local draft")
  }
  func testMainDirtySaveConflictKeepsTabAndRetriesWithoutPrematureSelection() async throws { try await dirtyConflict(taskWindow: false) }
  func testTaskDirtySaveConflictKeepsTabAndRetriesWithoutPrematureSelection() async throws { try await dirtyConflict(taskWindow: true) }

  func testLateMainSaveCannotCloseReplacementEditorForSameTab() async throws {
    let (store, root) = try fixture(), path = root.appendingPathComponent("file.txt")
    try "original".write(to: path, atomically: true, encoding: .utf8)
    store.project = root; store.workspace.setProject(root)
    XCTAssertTrue(store.openFileTab("file.txt")); let tab = try XCTUnwrap(store.activeWorkspaceContentTab)
    let old = store.fileTabWorkspace(tab); old.root = root; await old.openFile("file.txt")
    old.beginEditingSelectedFile(); old.editSelectedFile("saved old draft")
    store.closeWorkspaceTab(tab.id)
    let replacement = DeveloperWorkspace(); replacement.root = root
    store.fileTabWorkspaces[tab.id] = replacement
    for _ in 0..<80 where store.pendingWorkspaceTabCloses[tab.id] != nil { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertNil(store.pendingWorkspaceTabCloses[tab.id])
    XCTAssertTrue(store.workspaceTabs.contains(tab)); XCTAssertEqual(store.activeWorkspaceContentTab, tab)
    XCTAssertTrue(store.fileTabWorkspace(tab) === replacement)
    XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "saved old draft")
  }

  func testActualMainCloseKeyRemountsOpenerAndInactiveCloseKeepsComposerResponder() async throws {
    for mode in [WorkspaceContentLayoutMode.full, .split] {
      let (store, _) = try fixture(); defer { store.workspace.browser.shutdown() }
      store.workspaceContentLayoutMode = mode
      store.newBrowserTab(in: mode == .full ? .left : .right)
      let opener = try XCTUnwrap(mode == .full ? store.activeWorkspaceContentTab : store.activeRightWorkspaceContentTab)
      store.newBrowserTab(in: mode == .full ? .left : .right)
      let child = try XCTUnwrap(store.newBrowserChild(from: try XCTUnwrap(opener.browserID)))
      let window = KeyWindow(contentRect: .init(x: 0, y: 0, width: 1200, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; defer { window.contentView = nil; window.close() }
      let host = NSHostingView(rootView: AppContentView(store: store)); window.contentView = host
      try await Task.sleep(for: .milliseconds(220)); host.layoutSubtreeIfNeeded()
      XCTAssertTrue(child.view.window === window)
      try sendClose(in: window)
      try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded()
      XCTAssertTrue(child.closed); XCTAssertNil(child.view.window)
      XCTAssertEqual(store.focusedWorkspaceContentTab, opener)
      XCTAssertTrue(try XCTUnwrap(store.workspace.browser.tabs.first { $0.id == opener.browserID }).view.window === window)
      XCTAssertEqual(store.workspace.browser.addressFocusTarget, opener.browserID)
      XCTAssertTrue(try XCTUnwrap(store.workspace.browser.addressField?.currentEditor()) === window.firstResponder)
      let secondChild = try XCTUnwrap(store.newBrowserChild(from: try XCTUnwrap(opener.browserID)))
      store.activateChatTab()
      try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
      let editor = try XCTUnwrap(composer(in: host)); XCTAssertTrue(window.makeFirstResponder(editor))
      try await Task.sleep(for: .milliseconds(40))
      store.closeWorkspaceTab(WorkspaceContentTab.browser(secondChild.id, owner: "a").id)
      try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
      XCTAssertTrue(window.firstResponder === editor); XCTAssertNil(store.focusedWorkspaceContentTab)
      if mode == .split { XCTAssertTrue(try XCTUnwrap(store.workspace.browser.tabs.first { $0.id == opener.browserID }).view.window === window) }
      XCTAssertFalse(window.isVisible)
    }
  }

  func testActualTaskCloseKeyRemountsOpenerAndInactiveCloseKeepsComposerResponder() async throws {
    for mode in [WorkspaceContentLayoutMode.full, .split] {
      let (store, _) = try fixture()
      let resources = TaskWindowResources(); resources.prepare("a", store: store); defer { resources.shutdown() }
      let tabs = try XCTUnwrap(resources.tasks["a"]); tabs.contentLayoutMode = mode
      tabs.newBrowser(in: mode == .full ? .left : .right)
      let opener = try XCTUnwrap(tabs.selected(mode == .full ? .left : .right))
      tabs.newBrowser(in: mode == .full ? .left : .right)
      let child = try XCTUnwrap(tabs.browser.session.newChildTab(from: try XCTUnwrap(opener.browserID)))
      let window = KeyWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; defer { window.contentView = nil; window.close() }
      let host = NSHostingView(rootView: TaskWindowView(store: store, taskID: "a", tabs: tabs, resources: resources,
        renameHistory: TaskRenameHistory(), onNavigate: { _ in }, canGoBack: false, canGoForward: false, onMove: { _ in }))
      window.contentView = host
      try await Task.sleep(for: .milliseconds(220)); host.layoutSubtreeIfNeeded()
      XCTAssertTrue(child.view.window === window)
      try sendClose(in: window)
      try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded()
      XCTAssertTrue(child.closed); XCTAssertNil(child.view.window); XCTAssertEqual(tabs.focused, opener)
      XCTAssertTrue(try XCTUnwrap(tabs.browser.session.tabs.first { $0.id == opener.browserID }).view.window === window)
      XCTAssertEqual(tabs.browser.session.addressFocusTarget, opener.browserID)
      XCTAssertTrue(try XCTUnwrap(tabs.browser.session.addressField?.currentEditor()) === window.firstResponder)
      let secondChild = try XCTUnwrap(tabs.browser.session.newChildTab(from: try XCTUnwrap(opener.browserID)))
      tabs.activate(nil)
      try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
      let editor = try XCTUnwrap(composer(in: host)); XCTAssertTrue(window.makeFirstResponder(editor))
      try await Task.sleep(for: .milliseconds(40))
      tabs.close(WorkspaceContentTab.browser(secondChild.id, owner: "a").id)
      try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
      XCTAssertTrue(window.firstResponder === editor); XCTAssertNil(tabs.focused)
      if mode == .split { XCTAssertTrue(try XCTUnwrap(tabs.browser.session.tabs.first { $0.id == opener.browserID }).view.window === window) }
      XCTAssertFalse(window.isVisible)
    }
  }
}
