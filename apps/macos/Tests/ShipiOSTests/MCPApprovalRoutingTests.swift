import XCTest
@testable import ShipiOS

final class MCPApprovalRoutingTests: XCTestCase {
  @MainActor func testCodexOfferedDecisionsGuardButtonsAndShortcuts() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, first, _) = try fixture(root)
    let execution = try XCTUnwrap(store.mcpPendingApprovals[first]?.execution)
    store.mcpPendingApprovals[first] = MCPApprovalContext(runID: "run-1", execution: execution,
      allowsOnce: false, allowsTask: true)
    store.resolveMCPApproval(first, decision: .allowOnce)
    XCTAssertNotNil(store.mcpPendingApprovals[first])
    XCTAssertTrue(store.handleMCPApprovalShortcut(ShortcutBinding("↵"), taskID: "task-1", context: .init()))
    XCTAssertNil(store.mcpPendingApprovals[first])
    store.mcpPendingApprovals[first] = MCPApprovalContext(runID: "run-1", execution: execution,
      allowsOnce: false, allowsTask: false)
    XCTAssertFalse(store.commandEnabled("approval-approve"))
    XCTAssertTrue(store.commandEnabled("approval-decline"))
    XCTAssertFalse(store.handleMCPApprovalShortcut(ShortcutBinding("↵"), taskID: "task-1", context: .init()))
    XCTAssertNotNil(store.mcpPendingApprovals[first])
    store.resolveMCPApproval(first, decision: .deny)
    XCTAssertNil(store.mcpPendingApprovals[first])
  }

  @MainActor private func fixture(_ root: URL) throws -> (WorkspaceStore, UUID, UUID) {
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.restoringLibrary = false
    var ids: [UUID] = []
    for index in 1...2 {
      let task = "task-\(index)", runID = "run-\(index)"
      let execution = MCPToolExecution(callID: "call", serverID: UUID(), serverName: "server", toolName: "tool", arguments: "{}")
      let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode([execution]))
      let run = AgentRun(id: runID, kind: "chat", project: "", status: "running", createdAt: 0, updatedAt: 0,
        request: .object([:]), result: .object(["response": .string(""), "tool_executions": value]))
      store.library.tasks.append(WorkspaceTask(id: task, project: "", title: task, runIDs: [runID]))
      store.library.chatRuns.append(run)
      store.mcpPendingApprovals[execution.id] = MCPApprovalContext(runID: runID, execution: execution)
      ids.append(execution.id)
    }
    store.selection = "run-1"
    return (store, ids[0], ids[1])
  }

  @MainActor func testKeyboardAndFocusedMenuResolveOnlyTheirOwnTask() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, first, second) = try fixture(root)
    XCTAssertEqual(store.activeMCPApproval(taskID: "task-1"), first)
    let secondaryWindow = try XCTUnwrap(store.mcpApprovalCommands(taskID: "task-2", visible: true))
    secondaryWindow.decline()
    XCTAssertNil(store.mcpPendingApprovals[second])
    XCTAssertNotNil(store.mcpPendingApprovals[first])
    XCTAssertEqual(store.selection, "run-1")
    XCTAssertTrue(store.handleMCPApprovalShortcut(ShortcutBinding("↵"), taskID: "task-1", context: .init()))
    XCTAssertTrue(store.mcpPendingApprovals.isEmpty)
    XCTAssertFalse(store.handleMCPApprovalShortcut(ShortcutBinding("↵"), taskID: "task-1", context: .init()))
  }

  @MainActor func testTextCompositionPanelsSheetsRepeatsAndCaptureNeverConsumeApprovalKeys() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, first, _) = try fixture(root)
    let contexts: [MCPApprovalKeyContext] = [.init(visible: false), .init(hasSheet: true), .init(isRepeat: true),
      .init(editingText: true), .init(markedText: true), .init(ownsPanelInput: true)]
    for context in contexts {
      for key in ["↵", "⎋"] {
        XCTAssertFalse(store.handleMCPApprovalShortcut(ShortcutBinding(key), taskID: "task-1", context: context))
      }
      XCTAssertNotNil(store.mcpPendingApprovals[first])
    }
    store.shortcutCaptureCount = 1
    XCTAssertFalse(store.handleMCPApprovalShortcut(ShortcutBinding("↵"), taskID: "task-1", context: .init()))
    store.shortcutCaptureCount = 0
    store.openSettings(.plugins)
    XCTAssertFalse(store.mainMCPApprovalVisible)
    XCTAssertFalse(store.commandEnabled("approval-approve"))
    XCTAssertNil(store.mcpApprovalCommands(taskID: "task-1", visible: store.mainMCPApprovalVisible))
    store.closeSettings()
    XCTAssertTrue(store.commandEnabled("approval-decline"))
    store.executeCommand("approval-decline")
    XCTAssertNil(store.mcpPendingApprovals[first])
  }

  @MainActor func testCustomBindingsPersistAndBareKeysAreLimitedToApprovalCommands() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let preferences = ShortcutPreferences(file: root.appendingPathComponent("shortcuts.json"))
    XCTAssertEqual(preferences.binding("approval-approve"), ShortcutBinding("↵"))
    XCTAssertEqual(preferences.binding("approval-decline"), ShortcutBinding("⎋"))
    XCTAssertThrowsError(try preferences.set(ShortcutBinding("↵"), for: "search"))
    XCTAssertThrowsError(try preferences.set(ShortcutBinding("a"), for: "approval-approve"))
    try preferences.set(nil, for: "approval-decline")
    try preferences.set(ShortcutBinding("⎋"), for: "approval-approve")
    XCTAssertThrowsError(try preferences.reset("approval-decline"))
    try preferences.set(ShortcutBinding("⌘⇧Y"), for: "approval-approve")
    try preferences.reset("approval-decline")
    let reloaded = ShortcutPreferences(file: root.appendingPathComponent("shortcuts.json"))
    XCTAssertEqual(reloaded.binding("approval-approve"), ShortcutBinding("⌘⇧Y"))
    XCTAssertEqual(reloaded.binding("approval-decline"), ShortcutBinding("⎋"))
    try reloaded.resetAll()
    XCTAssertEqual(reloaded.binding("approval-approve"), ShortcutBinding("↵"))
  }

  @MainActor func testArchivedOrFinishedTasksNeverOfferApprovalCommands() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, _, _) = try fixture(root)
    store.library.tasks[0].archived = true
    XCTAssertNil(store.activeMCPApproval(taskID: "task-1"))
    XCTAssertNil(store.activeMCPApproval(taskID: "missing"))
    store.library.tasks[0].archived = false
    store.restoreInterruptedChats()
    XCTAssertNil(store.activeMCPApproval(taskID: "task-1"))
    XCTAssertNil(store.mcpApprovalCommands(taskID: "task-2", visible: true))
  }

  @MainActor func testAlternateApprovalBindingCannotBypassTheContextGuard() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, first, _) = try fixture(root)
    let alternate = ShortcutBinding("⌘⇧Y")
    try store.shortcuts.replace(nil, with: alternate, for: "approval-approve")
    XCTAssertFalse(store.handleWorkspaceShortcut(alternate))
    XCTAssertFalse(store.handleMCPApprovalShortcut(alternate, taskID: "task-1", context: .init(hasSheet: true)))
    XCTAssertNotNil(store.mcpPendingApprovals[first])
    XCTAssertTrue(store.handleMCPApprovalShortcut(alternate, taskID: "task-1", context: .init(editingText: true)))
    XCTAssertNil(store.mcpPendingApprovals[first])
  }
}
