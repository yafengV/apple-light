import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class TerminalRestartTests: XCTestCase {
  private final class TestWindow: NSWindow {
    var active = true
    override var isKeyWindow: Bool { active }
  }
  private func fixture() throws -> (WorkspaceStore, WorkspaceContentTab, TerminalSession) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-restart-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = WorkspaceStore(dataRoot: root)
    store.project = root; store.connected = true; store.scopeLoaded = true
    store.workspace.setProject(root)
    store.libraryLoaded = true
    store.library.tasks = [.init(id: "a", project: root.path, title: "A", runIDs: []),
      .init(id: "b", project: root.path, title: "B", runIDs: [])]
    store.selection = "a"
    store.restoreWorkspaceTabLayout()
    store.newTerminalTab(in: .detached)
    let tab = try XCTUnwrap(store.focusedWorkspaceContentTab)
    let session = try XCTUnwrap(store.terminalSession(try XCTUnwrap(tab.terminalID)))
    addTeardownBlock { @MainActor in
      store.workspace.terminals.shutdown()
      try? FileManager.default.removeItem(at: root)
    }
    return (store, tab, session)
  }
  private func eventually(_ message: String, _ condition: () -> Bool) async throws {
    for _ in 0..<100 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail(message)
  }

  func testRestartKeepsRoutePinsAndBackgroundLayoutWhileReplacingOnlyOneShell() throws {
    let (store, tab, first) = try fixture()
    store.pinWorkspaceTab(tab.id)
    let pin = try XCTUnwrap(store.library.pinnedContentTabs.first)
    store.newTerminalTab(in: .right)
    let other = try XCTUnwrap(store.terminalSession(try XCTUnwrap(store.activeRightWorkspaceContentTab?.terminalID)))
    let otherPID = other.view.process.shellPid
    store.applyTaskSelection(store.library.tasks[1])
    let before = store.workspaceTabLayoutSnapshot
    let oldLayout = store.library.workspaceTabLayouts["a"]
    let oldPID = first.view.process.shellPid
    let route = WorkspaceTabWindowRoute(tabID: tab.id)
    for _ in 0..<3 {
      let previous = try XCTUnwrap(store.terminalSession(first.id))
      let replacement = try XCTUnwrap(store.restartTerminalTab(first.id))
      XCTAssertFalse(replacement === previous)
      XCTAssertFalse(previous.view.process.running)
      XCTAssertEqual(replacement.id, first.id)
      XCTAssertTrue(replacement.view.process.running)
      XCTAssertNotEqual(replacement.view.process.shellPid, oldPID)
      XCTAssertTrue(store.workspaceTabs.contains { $0.id == route.tabID })
      XCTAssertEqual(store.workspaceTabPlacement(route.tabID), .detached)
    }
    XCTAssertEqual(store.currentWorkspaceTabOwner, "b")
    XCTAssertEqual(store.workspaceTabLayoutSnapshot, before)
    XCTAssertEqual(store.library.pinnedContentTabs.first, pin)
    store.saveLibrary()
    let disk = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(disk.workspaceTabLayouts["a"], oldLayout)
    XCTAssertTrue(store.terminalSession(other.id) === other)
    XCTAssertEqual(other.view.process.shellPid, otherPID)
    store.restoreDetachedWorkspaceTab(tab.id)
    XCTAssertEqual(store.workspaceTabPlacement(tab.id), .left)
  }

  func testMountedDetachedWindowReplacesNativeViewAndFocusesNewShellWithAnotherTaskSelected() async throws {
    let (store, tab, original) = try fixture()
    store.applyTaskSelection(store.library.tasks[1])
    let mainFocus = store.focusComposer
    let window = TestWindow(contentRect: .init(x: 0, y: 0, width: 700, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: WorkspaceTabWindowView(store: store, tabID: tab.id))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    defer { window.contentView = nil; window.close() }
    try await eventually("Original terminal was not mounted") { original.view.window === window }
    try await eventually("Detached terminal could not focus with B selected") { window.firstResponder === original.view }
    let replacement = try XCTUnwrap(store.restartTerminalTab(original.id))
    try await eventually("Restart left the window attached to its old terminal") {
      host.layoutSubtreeIfNeeded()
      return replacement.view.window === window && original.view.window == nil
    }
    try await eventually("Replacement shell did not receive keyboard focus") { window.firstResponder === replacement.view }
    XCTAssertEqual(store.selection, "b")
    XCTAssertEqual(store.focusComposer, mainFocus)
    XCTAssertEqual(store.workspaceTabs.filter { $0.id == tab.id }.count, 1)
  }

  func testInactiveDetachedWindowDoesNotStealFocusWhenItsShellIsReplaced() async throws {
    let (store, tab, original) = try fixture()
    let window = TestWindow(contentRect: .init(x: 0, y: 0, width: 700, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.active = false
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: WorkspaceTabWindowView(store: store, tabID: tab.id))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    defer { window.contentView = nil; window.close() }
    try await eventually("Original terminal was not mounted") { original.view.window === window }
    let replacement = try XCTUnwrap(store.restartTerminalTab(original.id))
    try await eventually("Replacement terminal was not mounted") {
      host.layoutSubtreeIfNeeded()
      return replacement.view.window === window && replacement.view.focusCoordinator != nil
    }
    XCTAssertFalse(window.firstResponder === replacement.view)
    window.active = true
    replacement.view.focusCoordinator?.scheduleFocus()
    try await eventually("Pending focus did not resume on activation") { window.firstResponder === replacement.view }
  }

  func testMissingTabAndShutdownCannotStartReplacementProcesses() throws {
    let (store, tab, original) = try fixture()
    store.shuttingDown = true
    XCTAssertNil(store.restartTerminalTab(original.id))
    XCTAssertTrue(store.terminalSession(original.id) === original)
    store.shuttingDown = false
    store.closeWorkspaceTab(tab.id)
    XCTAssertNil(store.restartTerminalTab(original.id))
    XCTAssertFalse(original.view.process.running)
  }
}
