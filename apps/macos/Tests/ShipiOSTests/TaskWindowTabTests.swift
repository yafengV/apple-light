import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class TaskWindowTabTests: XCTestCase {
  func testEnvironmentActionUsesDetachedTasksOwnTerminal() async throws {
    let (store, resources, tabs) = try fixture()
    defer { resources.shutdown() }
    let action = EnvironmentAction(title: "Test", symbol: "checkmark.circle",
      script: "printf 'detached' > action-result")
    XCTAssertTrue(tabs.runEnvironmentAction(action, in: .bottom))
    let session = try XCTUnwrap(tabs.panels.terminal)
    XCTAssertEqual(tabs.title(try XCTUnwrap(tabs.selected(.bottom))), "Test")
    try await eventually("Detached action did not run") {
      FileManager.default.fileExists(atPath: session.root.appendingPathComponent("action-result").path)
    }
    XCTAssertEqual(try String(contentsOf: session.root.appendingPathComponent("action-result")),
      "detached")
    XCTAssertEqual(tabs.selected(.bottom)?.terminalID, session.id)
    XCTAssertNil(store.focusedWorkspaceContentTab)
  }

  private func fixture() throws -> (WorkspaceStore, TaskWindowResources, TaskWindowTabs) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("window-tabs-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.library.tasks = [.init(id: "popup", project: root.path, title: "Popup", runIDs: [])]
    store.selection = "main"
    store.library.drafts["main"] = "keep main"
    let resources = TaskWindowResources()
    resources.prepare("popup", store: store)
    return (store, resources, try XCTUnwrap(resources.tasks["popup"]))
  }

  func testPlanDocumentTabRemainsInDetachedTaskAndRestores() throws {
    let (store, resources, tabs) = try fixture()
    defer { resources.shutdown() }
    let document = CodexPlanDocument(id: "plan-1", text: "# Detached plan\nDetails")
    let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(document))
    let run = AgentRun(id: "plan-run", kind: "chat", project: store.library.tasks[0].project,
      status: "succeeded", createdAt: 0, updatedAt: 0, request: .null,
      result: .object(["codex_plan_document": value]))
    store.library.tasks[0].runIDs = [run.id]
    store.library.chatRuns = [run]
    store.runs = [run]
    tabs.openPlan(runID: run.id)
    let tab = try XCTUnwrap(tabs.selected(.left))
    XCTAssertEqual(tab, .plan(run.id, owner: "popup"))
    XCTAssertEqual(tabs.title(tab), "Detached plan")
    XCTAssertEqual(tabs.layoutSnapshot.content.tabs.first?.kind, .plan)
    XCTAssertEqual(store.selection, "main", "The main window stays on its own task")
    let saved = tabs.layoutSnapshot
    tabs.close(tab.id)
    tabs.reopen()
    XCTAssertEqual(tabs.selected(.left), tab)

    let restoredResources = TaskWindowResources()
    defer { restoredResources.shutdown() }
    restoredResources.prepare("popup", store: store)
    let restored = try XCTUnwrap(restoredResources.tasks["popup"])
    restored.restoreLayout(saved)
    XCTAssertEqual(restored.selected(.left), tab)
    restored.resetProjectTabs()
    XCTAssertEqual(restored.selected(.left), tab, "A plan document survives a worktree project change")
  }
  func testSourcesTabRemainsInDetachedTaskAndRestores() throws {
    let (store, resources, tabs) = try fixture()
    defer { resources.shutdown() }
    tabs.openSources()
    let tab = try XCTUnwrap(tabs.selected(.left))
    XCTAssertEqual(tab, .sources(owner: "popup"))
    XCTAssertEqual(tabs.title(tab), "来源")
    XCTAssertEqual(tabs.layoutSnapshot.content.tabs.first?.kind, .sources)
    XCTAssertEqual(store.selection, "main")
    let saved = tabs.layoutSnapshot
    tabs.close(tab.id)
    tabs.reopen()
    XCTAssertEqual(tabs.selected(.left), tab)

    let restoredResources = TaskWindowResources()
    defer { restoredResources.shutdown() }
    restoredResources.prepare("popup", store: store)
    let restored = try XCTUnwrap(restoredResources.tasks["popup"])
    restored.restoreLayout(saved)
    XCTAssertEqual(restored.selected(.left), tab)
    restored.resetProjectTabs()
    XCTAssertEqual(restored.selected(.left), tab)
  }
  private func output(_ session: TerminalSession) -> String {
    String(decoding: session.view.getTerminal().getBufferAsData(), as: UTF8.self)
  }
  private func send(_ text: String, to session: TerminalSession) {
    session.view.process.send(data: Array(text.utf8)[...])
  }
  private func eventually(_ message: String, _ condition: () -> Bool) async throws {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTFail(message)
  }

  func testMixedContentOrderNumericFocusAndScopedCommands() throws {
    let (store, resources, tabs) = try fixture()
    defer { resources.shutdown() }
    tabs.newBrowser()
    let browser = try XCTUnwrap(tabs.selected(.left))
    tabs.openReview(defaultScope: .staged)
    let review = try XCTUnwrap(tabs.selected(.left))
    tabs.newTerminal()
    let terminal = try XCTUnwrap(tabs.selected(.bottom))
    XCTAssertEqual(tabs.tabs, [browser, review, terminal])
    tabs.focusSlot(1)
    XCTAssertTrue(tabs.chatVisible)
    XCTAssertNil(tabs.focused)
    tabs.focusSlot(2)
    XCTAssertEqual(tabs.focused, browser)
    tabs.focusSlot(3)
    XCTAssertEqual(tabs.focused, review)
    tabs.focusSlot(4)
    XCTAssertEqual(tabs.focused, terminal)
    tabs.focusSlot(9)
    XCTAssertEqual(tabs.focused, terminal)
    tabs.cycle(1)
    XCTAssertNil(tabs.focused)
    tabs.cycle(-1)
    XCTAssertEqual(tabs.focused, terminal)
    XCTAssertEqual(store.selection, "main")
    XCTAssertEqual(store.library.drafts["main"], "keep main")
    XCTAssertTrue(store.workspaceTabs.isEmpty)
  }

  func testPaneMovesNeverDuplicateWebViewsAndCloseOnlyOwnPane() throws {
    let (_, resources, tabs) = try fixture()
    defer { resources.shutdown() }
    tabs.newBrowser()
    let first = try XCTUnwrap(tabs.selected(.left)), webView = try XCTUnwrap(tabs.browser.session.selected).view
    tabs.newBrowser(in: .right)
    let right = try XCTUnwrap(tabs.selected(.right))
    tabs.activate(first.id)
    tabs.toggleFullWidth()
    XCTAssertEqual(tabs.placement(first.id), .right)
    XCTAssertTrue(tabs.chatVisible)
    XCTAssertTrue(tabs.browser.session.tabs.first { $0.id == first.browserID }?.view === webView)
    tabs.toggleFullWidth()
    XCTAssertEqual(tabs.placement(first.id), .left)
    XCTAssertEqual(tabs.selected(.right), right)
    XCTAssertFalse(tabs.canMove(first.id, to: .bottom))
    tabs.move(first.id, to: .bottom)
    XCTAssertEqual(tabs.placement(first.id), .left)
    tabs.newBrowser()
    let last = try XCTUnwrap(tabs.selected(.left))
    tabs.closeOthers(keeping: first.id, in: .left)
    XCTAssertFalse(tabs.tabs.contains(last))
    XCTAssertTrue(tabs.tabs.contains(right))
    XCTAssertEqual(tabs.selected(.right), right)
    tabs.close(first.id)
    XCTAssertTrue(tabs.chatVisible)
    XCTAssertEqual(tabs.selected(.right), right, "Closing a main tab must not select a right-pane page into main")
    XCTAssertEqual(tabs.tabs.count, 1)
    tabs.activate(right.id)
    XCTAssertTrue(tabs.commandEnabled("browser-close"))
    XCTAssertFalse(tabs.commandEnabled("browser-back"))
    tabs.perform("workspace-tabs")
    XCTAssertFalse(tabs.showingTabs)
    tabs.perform("workspace-swap-panes")
    XCTAssertEqual(tabs.primarySide, .right)
  }

  func testMixedCloseHistoryReopensInOriginalPaneAndBrowserFallbackStaysLocal() throws {
    let (_, resources, tabs) = try fixture()
    defer { resources.shutdown() }
    tabs.newBrowser(in: .right)
    let first = try XCTUnwrap(tabs.selected(.right))
    tabs.browser.session.selected?.address = "unfinished address"
    tabs.newBrowser()
    let main = try XCTUnwrap(tabs.selected(.left))
    tabs.activate(first.id)
    tabs.close(first.id)
    XCTAssertEqual(tabs.selected(.left), main)
    XCTAssertFalse(tabs.showingRight)
    tabs.openReview(defaultScope: .unstaged)
    let review = try XCTUnwrap(tabs.selected(.left))
    tabs.close(review.id)
    tabs.reopen()
    XCTAssertEqual(tabs.selected(.left), review)
    tabs.reopen()
    XCTAssertEqual(tabs.selected(.right)?.browserID, tabs.browser.session.selection)
    XCTAssertEqual(tabs.browser.session.selected?.address, "unfinished address")
    XCTAssertEqual(tabs.placement(try XCTUnwrap(tabs.selected(.right)).id), .right)
    XCTAssertFalse(tabs.canReopen)
  }

  func testReorderCloseRightAndChatCloseOthersRespectPaneBoundaries() throws {
    let (_, resources, tabs) = try fixture()
    defer { resources.shutdown() }
    tabs.newBrowser(); let first = try XCTUnwrap(tabs.selected(.left))
    tabs.openReview(defaultScope: .unstaged); let review = try XCTUnwrap(tabs.selected(.left))
    tabs.newBrowser(); let last = try XCTUnwrap(tabs.selected(.left))
    tabs.newBrowser(in: .right); let right = try XCTUnwrap(tabs.selected(.right))
    XCTAssertTrue(tabs.reorder(last.id, relativeTo: first.id, after: false))
    XCTAssertEqual(tabs.visibleTabs(.left), [last, first, review])
    XCTAssertFalse(tabs.reorder(right.id, relativeTo: first.id, after: false))
    tabs.closeRight(of: first.id, in: .left)
    XCTAssertEqual(tabs.visibleTabs(.left), [last, first])
    tabs.closeOthers(keeping: nil, in: .left)
    XCTAssertEqual(tabs.tabs, [right])
    XCTAssertTrue(tabs.chatVisible)
    XCTAssertEqual(tabs.selected(.right), right)
  }

  func testMultipleTerminalsRetainExactShellAcrossMovesAndRestartOnlyOne() async throws {
    let (_, resources, tabs) = try fixture()
    defer { resources.shutdown() }
    tabs.newTerminal()
    let firstTab = try XCTUnwrap(tabs.selected(.bottom)), first = try XCTUnwrap(tabs.panels.terminal)
    send("export TAB_TEST=first; print -r -- READY:$TAB_TEST\r", to: first)
    try await eventually("First terminal not ready") { self.output(first).contains("READY:first") }
    tabs.newTerminal()
    let secondTab = try XCTUnwrap(tabs.selected(.bottom)), second = try XCTUnwrap(tabs.panels.terminal)
    send("print -r -- SECOND:${TAB_TEST-unset}\r", to: second)
    try await eventually("Second terminal inherited first state") { self.output(second).contains("SECOND:unset") }
    for place in [WorkspaceTabPlacement.left, .right, .bottom] {
      tabs.move(firstTab.id, to: place)
      XCTAssertTrue(tabs.panels.terminal === first)
      XCTAssertEqual(tabs.panels.terminalFocus?.sessionID, first.id)
      XCTAssertEqual(tabs.selected(place), firstTab)
    }
    tabs.hide(.bottom)
    XCTAssertEqual(first.status, .running)
    tabs.activate(firstTab.id)
    send("print -r -- RETURNED:$TAB_TEST\r", to: first)
    try await eventually("Moving terminal reset state") { self.output(first).contains("RETURNED:first") }
    tabs.restartTerminal(first.id)
    XCTAssertEqual(first.status, .stopped)
    XCTAssertFalse(tabs.tabs.contains(firstTab))
    XCTAssertEqual(second.status, .running)
    XCTAssertTrue(tabs.tabs.contains(secondTab))
    tabs.close(secondTab.id)
    XCTAssertEqual(second.status, .stopped)
    tabs.reopen()
    XCTAssertEqual(tabs.selected(.bottom)?.terminalID, tabs.panels.terminal?.id)
    XCTAssertNotEqual(tabs.panels.terminal?.id, second.id)
  }

  func testProjectChangeRemovesProjectTabsButKeepsBrowserAndOtherTasks() throws {
    let (store, resources, tabs) = try fixture()
    defer { resources.shutdown() }
    tabs.newBrowser(); let page = try XCTUnwrap(tabs.selected(.left))
    tabs.openReview(defaultScope: .unstaged)
    tabs.newTerminal(); let terminal = try XCTUnwrap(tabs.panels.terminal)
    store.library.tasks[0].project = ""
    resources.prepare("popup", store: store)
    XCTAssertEqual(tabs.tabs, [page])
    XCTAssertEqual(terminal.status, .stopped)
    XCTAssertFalse(tabs.showingBottom)
    XCTAssertNil(tabs.panels.workspace.root)
    tabs.newTerminal()
    tabs.openReview(defaultScope: .unstaged)
    XCTAssertEqual(tabs.tabs, [page])
    XCTAssertEqual(store.selection, "main")
  }

  func testBackgroundLinksKeepChatAndRejectForeignWindowDrags() throws {
    let (store, resources, tabs) = try fixture()
    defer { resources.shutdown() }
    let chatFocus = tabs.chatFocus
    tabs.openBrowser(URL(string: "http://127.0.0.1:9/one")!, presentation: .backgroundTab)
    XCTAssertEqual(tabs.tabs.count, 1)
    XCTAssertTrue(tabs.chatVisible)
    XCTAssertNil(tabs.focusedID)
    XCTAssertEqual(tabs.chatFocus, chatFocus)
    XCTAssertTrue(tabs.showingRight)
    XCTAssertNil(tabs.browser.session.selection)
    let first = try XCTUnwrap(tabs.tabs.first)
    tabs.activate(first.id)
    tabs.openBrowser(URL(string: "http://127.0.0.1:9/two")!, presentation: .backgroundTab)
    XCTAssertEqual(tabs.focusedID, first.id)
    tabs.openBrowser(URL(fileURLWithPath: "/tmp/invalid"), presentation: .fullWidth)
    XCTAssertEqual(tabs.placement(first.id), .right)
    let other = TaskWindowResources()
    defer { other.shutdown() }
    other.prepare("popup", store: store)
    let otherTabs = try XCTUnwrap(other.tasks["popup"])
    tabs.openReview(defaultScope: .unstaged)
    otherTabs.openReview(defaultScope: .unstaged)
    let review = WorkspaceContentTab.review(owner: "popup")
    XCTAssertEqual(tabs.draggedTab(tabs.dragToken(review.id)), review.id)
    XCTAssertNil(otherTabs.draggedTab(tabs.dragToken(review.id)))
    XCTAssertNil(tabs.draggedTab(WorkspaceTabDragToken.encode(review.id)))
    tabs.newTerminal()
    tabs.activate(first.id)
    let focused = tabs.focusedID
    tabs.close(review.id)
    XCTAssertEqual(tabs.focusedID, focused, "Closing a background tab must not steal focus")
  }

}
