import AppKit
import XCTest

@testable import ShipiOS

final class TerminalSessionTests: XCTestCase {
  @MainActor func testTerminalShortcutUsesConfiguredRightPanelAndTogglesIt() throws {
    let store = WorkspaceStore()
    store.project = URL(fileURLWithPath: "/tmp")
    store.library.defaultTerminalLocation = .right
    store.executeCommand("terminal")
    XCTAssertTrue(store.showingInspector)
    XCTAssertNotNil(store.activeRightWorkspaceContentTab?.terminalID)
    XCTAssertFalse(store.showingTerminal)
    store.executeCommand("terminal")
    XCTAssertFalse(store.showingInspector)
    store.workspace.terminals.shutdown()
  }

  @MainActor func testFocusRequestCannotEscapeItsTaskOrStealSettingsFocus() throws {
    let store = WorkspaceStore()
    store.project = URL(fileURLWithPath: "/tmp")
    store.executeCommand("terminal")
    let original = try XCTUnwrap(store.terminalFocusRequest)
    XCTAssertTrue(store.canFocusTerminal(original))
    store.openSettings(.general)
    XCTAssertFalse(store.canFocusTerminal(original))
    store.closeSettings()
    XCTAssertFalse(store.canFocusTerminal(original))
    store.focusTerminal()
    let current = try XCTUnwrap(store.terminalFocusRequest)
    XCTAssertTrue(store.canFocusTerminal(current))
    store.showingModelPicker = true
    XCTAssertFalse(store.canFocusTerminal(current))
    store.showingModelPicker = false
    store.showingBranchPicker = true
    XCTAssertFalse(store.canFocusTerminal(current))
    store.showingBranchPicker = false
    store.showingCommands = true
    XCTAssertFalse(store.canFocusTerminal(current))
    store.showingCommands = false
    store.focusTerminal()
    let changedTask = try XCTUnwrap(store.terminalFocusRequest)
    store.selection = "other-task"
    XCTAssertFalse(store.canFocusTerminal(changedTask))
    let composer = store.focusComposer
    store.executeCommand("bottom-panel")
    XCTAssertFalse(store.showingTerminal)
    XCTAssertNotEqual(store.focusComposer, composer)
  }
  @MainActor private func folder() throws -> URL {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal test \(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return GitBranchService.canonicalRoot(root)
  }
  @MainActor private func output(_ session: TerminalSession) -> String {
    String(decoding: session.view.getTerminal().getBufferAsData(), as: UTF8.self)
  }
  @MainActor private func send(_ text: String, to session: TerminalSession) {
    session.view.process.send(data: Array(text.utf8)[...])
  }
  @MainActor private func eventually(_ message: String, _ condition: () -> Bool) async throws {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(nanoseconds: 25_000_000)
    }
    XCTFail(message)
  }

  @MainActor func testRealShellsKeepIndependentVariablesAndWorkingDirectories() async throws {
    let root = try folder()
    let manager = TerminalSessions()
    defer { manager.shutdown() }
    let firstScope = TerminalScope(root: root, conversation: "first")
    let secondScope = TerminalScope(root: root, conversation: "second")
    let first = manager.session(for: firstScope)
    let second = manager.session(for: secondScope)
    XCTAssertNotEqual(first.view.process.shellPid, second.view.process.shellPid)
    send("export SHIPIOS_QA_TOKEN=alpha; print -r -- STATE:$SHIPIOS_QA_TOKEN; print -r -- \"$PWD\" > .first-cwd\r", to: first)
    send("print -r -- STATE:${SHIPIOS_QA_TOKEN-unset}; print -r -- \"$PWD\" > .second-cwd\r", to: second)
    try await eventually("First terminal did not execute commands") { self.output(first).contains("STATE:alpha") }
    try await eventually("Second terminal inherited another task's state") { self.output(second).contains("STATE:unset") }
    try await eventually("First terminal used the wrong directory") {
      FileManager.default.fileExists(atPath: root.appendingPathComponent(".first-cwd").path)
    }
    try await eventually("Second terminal used the wrong directory") {
      FileManager.default.fileExists(atPath: root.appendingPathComponent(".second-cwd").path)
    }
    for name in [".first-cwd", ".second-cwd"] {
      let actual = try String(contentsOf: root.appendingPathComponent(name)).trimmingCharacters(in: .newlines)
      XCTAssertEqual(GitBranchService.canonicalRoot(URL(fileURLWithPath: actual)), root)
    }
    XCTAssertTrue(manager.session(for: firstScope) === first)
    let worktree = try folder()
    let third = manager.session(for: TerminalScope(root: worktree, conversation: "first"))
    XCTAssertFalse(third === first)
    send("print -r -- \"$PWD\" > .worktree-cwd\r", to: third)
    try await eventually("Worktree terminal used the wrong directory") {
      FileManager.default.fileExists(atPath: worktree.appendingPathComponent(".worktree-cwd").path)
    }
    let actual = try String(contentsOf: worktree.appendingPathComponent(".worktree-cwd")).trimmingCharacters(in: .newlines)
    XCTAssertEqual(GitBranchService.canonicalRoot(URL(fileURLWithPath: actual)), worktree)
  }

  @MainActor func testNaturalExitRetainsOutputAndExplicitRestartCreatesNewShell() async throws {
    let root = try folder()
    let manager = TerminalSessions()
    defer { manager.shutdown() }
    let scope = TerminalScope(root: root, conversation: "task")
    let first = manager.session(for: scope)
    send("print -r -- COMPLETED; exit 7\r", to: first)
    try await eventually("Terminal exit status not reported") { first.status == .exited(7) }
    XCTAssertTrue(output(first).contains("COMPLETED"))
    XCTAssertTrue(manager.session(for: scope) === first)
    first.stop()
    XCTAssertEqual(first.status, .exited(7))
    let replacement = manager.restart(scope)
    XCTAssertNotEqual(first.id, replacement.id)
    XCTAssertEqual(replacement.status, .running)
    XCTAssertFalse(output(replacement).contains("COMPLETED"))
  }

  @MainActor func testStopTerminatesForegroundCommandAndReapsShellWithoutAffectingOtherTasks() async throws {
    let root = try folder()
    let manager = TerminalSessions()
    defer { manager.shutdown() }
    let first = manager.session(for: TerminalScope(root: root, conversation: "first"))
    let second = manager.session(for: TerminalScope(root: root, conversation: "second"))
    let shell = first.view.process.shellPid
    send("sleep 30\r", to: first)
    try await eventually("Foreground job did not start") {
      let group = tcgetpgrp(first.view.process.childfd)
      return group > 0 && group != shell
    }
    let foreground = tcgetpgrp(first.view.process.childfd)
    first.stop()
    XCTAssertEqual(first.status, .stopped)
    try await eventually("Foreground process is still alive") { kill(foreground, 0) == -1 && errno == ESRCH }
    try await eventually("Shell was not reaped") { kill(shell, 0) == -1 && errno == ESRCH }
    send("print -r -- STILL_ALIVE\r", to: second)
    try await eventually("Stopping one terminal affected another") { self.output(second).contains("STILL_ALIVE") }
  }

  @MainActor func testDraftPromotionPreservesShellAndNewDraftStartsIndependently() async throws {
    let root = try folder()
    let store = WorkspaceStore()
    store.project = root
    let draftScope = try XCTUnwrap(store.terminalScope)
    let original = store.workspace.terminals.session(for: draftScope)
    defer { store.workspace.terminals.shutdown() }
    send("export SHIPIOS_QA_TOKEN=before; print -r -- READY:$SHIPIOS_QA_TOKEN\r", to: original)
    try await eventually("Draft terminal not ready") { self.output(original).contains("READY:before") }
    let run = AgentRun(id: "first-run", kind: "chat", project: root.path, status: "succeeded",
      createdAt: 0, updatedAt: 0, request: .null, result: nil)
    store.library.attach(run, to: nil, note: "Task")
    store.adoptDraftTerminal(draftScope, run: run)
    store.selection = run.id
    let taskScope = try XCTUnwrap(store.terminalScope)
    XCTAssertTrue(store.workspace.terminals.session(for: taskScope) === original)
    store.showingTerminal = false
    store.openSettings(.general)
    store.closeSettings()
    store.showingTerminal = true
    XCTAssertTrue(store.workspace.terminals.session(for: try XCTUnwrap(store.terminalScope)) === original)
    store.newTask()
    let next = store.workspace.terminals.session(for: try XCTUnwrap(store.terminalScope))
    XCTAssertFalse(next === original)
    send("print -r -- STATE:${SHIPIOS_QA_TOKEN-unset}\r", to: next)
    try await eventually("New draft reused submitted task's environment") { self.output(next).contains("STATE:unset") }
    store.selection = run.id
    XCTAssertTrue(store.workspace.terminals.session(for: try XCTUnwrap(store.terminalScope)) === original)
    store.project = nil
    XCTAssertNil(store.terminalScope)
  }

  @MainActor func testAdoptionDoesNotOverwriteExistingOrCrossProjectSessions() throws {
    let root = try folder()
    let other = try folder()
    let manager = TerminalSessions()
    defer { manager.shutdown() }
    let draft = TerminalScope(root: root, conversation: "draft")
    let existing = TerminalScope(root: root, conversation: "existing")
    let foreign = TerminalScope(root: other, conversation: "foreign")
    let a = manager.session(for: draft)
    let b = manager.session(for: existing)
    manager.adopt(from: draft, to: existing)
    XCTAssertTrue(manager.session(for: draft) === a)
    XCTAssertTrue(manager.session(for: existing) === b)
    manager.adopt(from: draft, to: foreign)
    XCTAssertTrue(manager.session(for: draft) === a)
    XCTAssertFalse(manager.session(for: foreign) === a)
  }

  @MainActor func testTerminalTitleIsUpdatedByRealEscapeSequence() async throws {
    let root = try folder()
    let manager = TerminalSessions()
    defer { manager.shutdown() }
    let session = manager.session(for: TerminalScope(root: root, conversation: "title"))
    send("printf '\\033]0;Build output\\007'\r", to: session)
    try await eventually("Title escape sequence was not handled") { session.title == "Build output" }
    XCTAssertEqual(TerminalStatus.processExit(15), .signalled(15))
    XCTAssertEqual(TerminalStatus.processExit(nil), .launchFailed)
  }

  @MainActor func testLocalAgentSubmissionAdoptsDraftTerminal() async throws {
    var repository = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { repository.deleteLastPathComponent() }
    let root = try folder()
    let data = root.appendingPathComponent("data")
    let project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let store = WorkspaceStore(dataRoot: data, agentExecutable: repository.appendingPathComponent("target/debug/shipios-agent"))
    await store.restore()
    store.notificationPreferences = .init(timing: .never)
    await store.open(project)
    XCTAssertTrue(store.connected, store.error ?? "")
    let draftScope = try XCTUnwrap(store.terminalScope)
    let shell = store.workspace.terminals.session(for: draftScope)
    defer { store.workspace.terminals.shutdown() }
    store.draft = "/doctor inspect"
    await store.sendDraft()
    let scope = try XCTUnwrap(store.terminalScope)
    XCTAssertNotNil(store.selectedTask)
    XCTAssertNotEqual(scope, draftScope)
    XCTAssertTrue(store.workspace.terminals.session(for: scope) === shell)
    await store.shutdown()
  }
}
