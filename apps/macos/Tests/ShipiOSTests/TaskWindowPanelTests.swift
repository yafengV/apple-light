import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class TaskWindowPanelTests: XCTestCase {
  private func folder() throws -> URL {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("window-panels-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return GitBranchService.canonicalRoot(root)
  }
  private func send(_ text: String, to session: TerminalSession) {
    session.view.process.send(data: Array(text.utf8)[...])
  }
  private func output(_ session: TerminalSession) -> String {
    String(decoding: session.view.getTerminal().getBufferAsData(), as: UTF8.self)
  }
  private func eventually(_ message: String, _ condition: () -> Bool) async throws {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTFail(message)
  }

  func testTaskNavigationAndHiddenPanelsPreserveFilesAndRunningShell() async throws {
    let firstRoot = try folder(), secondRoot = try folder()
    try "let first = true\n".write(to: firstRoot.appendingPathComponent("First.swift"), atomically: true, encoding: .utf8)
    let manager = TaskWindowPanelSessions()
    defer { manager.shutdown() }
    let first = manager.panels(for: "first", project: firstRoot.path)
    await first.workspace.openFile("First.swift")
    first.showingFiles = true
    first.workspace.commitMessage = "unsubmitted review message"
    first.toggleTerminal()
    let shell = try XCTUnwrap(first.terminal)
    let pid = shell.view.process.shellPid
    send("export SHIPIOS_PANEL_STATE=kept; print -r -- READY:$SHIPIOS_PANEL_STATE\r", to: shell)
    try await eventually("First shell did not initialize") { self.output(shell).contains("READY:kept") }
    first.hideTerminal()
    let second = manager.panels(for: "second", project: secondRoot.path)
    second.toggleTerminal()
    let other = try XCTUnwrap(second.terminal)
    send("print -r -- OTHER:${SHIPIOS_PANEL_STATE-unset}\r", to: other)
    try await eventually("Tasks shared terminal state") { self.output(other).contains("OTHER:unset") }
    let returned = manager.panels(for: "first", project: firstRoot.path)
    XCTAssertTrue(returned === first)
    XCTAssertTrue(returned.workspace === first.workspace)
    XCTAssertEqual(returned.workspace.selectedFile, "First.swift")
    XCTAssertEqual(returned.workspace.openFiles, ["First.swift"])
    XCTAssertEqual(returned.workspace.fileText, "let first = true\n")
    XCTAssertEqual(returned.workspace.commitMessage, "unsubmitted review message")
    XCTAssertTrue(returned.showingFiles)
    returned.toggleTerminal()
    XCTAssertTrue(returned.terminal === shell)
    XCTAssertEqual(shell.view.process.shellPid, pid)
    send("print -r -- RETURNED:$SHIPIOS_PANEL_STATE\r", to: shell)
    try await eventually("Returning replaced or stopped the original shell") { self.output(shell).contains("RETURNED:kept") }
    XCTAssertNotEqual(pid, other.view.process.shellPid)
    XCTAssertEqual(returned.terminalFocus?.sessionID, shell.id)
    manager.shutdown()
    try await eventually("Window closure did not reap shells") {
      kill(pid, 0) == -1 && errno == ESRCH && !other.view.process.running
    }
  }

  func testDifferentWindowsAndExplicitRestartAreIsolated() async throws {
    let root = try folder()
    let firstWindow = TaskWindowPanelSessions(), secondWindow = TaskWindowPanelSessions()
    defer { firstWindow.shutdown(); secondWindow.shutdown() }
    let first = firstWindow.panels(for: "same-task", project: root.path)
    let second = secondWindow.panels(for: "same-task", project: root.path)
    first.toggleTerminal(); second.toggleTerminal()
    let original = try XCTUnwrap(first.terminal), other = try XCTUnwrap(second.terminal)
    XCTAssertFalse(first.workspace === second.workspace)
    XCTAssertNotEqual(original.view.process.shellPid, other.view.process.shellPid)
    send("print -r -- ORIGINAL_OUTPUT; exit 7\r", to: original)
    try await eventually("Exit status missing") { original.status == .exited(7) }
    first.hideTerminal(); first.toggleTerminal()
    XCTAssertTrue(first.terminal === original)
    XCTAssertTrue(output(original).contains("ORIGINAL_OUTPUT"))
    first.restartTerminal()
    XCTAssertFalse(first.terminal === original)
    XCTAssertEqual(first.terminal?.status, .running)
    XCTAssertEqual(first.terminalFocus?.sessionID, first.terminal?.id)
    firstWindow.shutdown()
    send("print -r -- OTHER_WINDOW_ALIVE\r", to: other)
    try await eventually("Closing one window stopped the other") { self.output(other).contains("OTHER_WINDOW_ALIVE") }
  }

  func testProjectChangeAndDeletionReleaseOnlyTheirOwnResources() async throws {
    let root = try folder(), replacement = try folder()
    let manager = TaskWindowPanelSessions()
    defer { manager.shutdown() }
    let first = manager.panels(for: "first", project: root.path)
    first.toggleTerminal()
    let old = try XCTUnwrap(first.terminal)
    first.workspace.openFiles = ["old.swift"]
    let alias = root.appendingPathComponent(".").path
    XCTAssertTrue(manager.panels(for: "first", project: alias).terminal === old)
    first.configure(project: replacement.path)
    XCTAssertEqual(old.status, .stopped)
    XCTAssertNil(first.terminal)
    XCTAssertTrue(first.workspace.openFiles.isEmpty)
    XCTAssertFalse(first.showingTerminal)
    first.toggleTerminal()
    XCTAssertEqual(first.terminal?.root, replacement)
    let second = manager.panels(for: "second", project: root.path)
    second.toggleTerminal()
    let survivor = try XCTUnwrap(second.terminal)
    manager.retainTasks(["second"], displaying: "first")
    XCTAssertNotNil(manager.tasks["first"], "Keep deleted task's mounted unavailable page")
    XCTAssertNil(first.terminal)
    XCTAssertEqual(survivor.status, .running)
    manager.retainTasks(["second"], displaying: "second")
    XCTAssertNil(manager.tasks["first"])
    second.configure(project: "")
    XCTAssertNil(second.workspace.root)
    second.toggleTerminal()
    XCTAssertNil(second.terminal)
  }

  func testApplicationShutdownCleansRegisteredWindowsWithoutRetainingThem() async throws {
    let root = try folder()
    let store = WorkspaceStore(dataRoot: root)
    var manager: TaskWindowPanelSessions? = TaskWindowPanelSessions()
    store.additionalTaskWindowPanels.add(try XCTUnwrap(manager))
    let panels = try XCTUnwrap(manager).panels(for: "task", project: root.path)
    panels.toggleTerminal()
    let terminal = try XCTUnwrap(panels.terminal)
    await store.shutdown()
    XCTAssertEqual(terminal.status, .stopped)
    XCTAssertTrue(manager?.tasks.isEmpty == true)
    manager = nil
    // shutdown's allObjects snapshot may be autoreleased until the event loop drains.
    // Check registry ownership independently of that temporary snapshot.
    weak var transient: TaskWindowPanelSessions?
    autoreleasepool {
      let candidate = TaskWindowPanelSessions()
      transient = candidate
      store.additionalTaskWindowPanels.add(candidate)
    }
    XCTAssertNil(transient)
  }
}
