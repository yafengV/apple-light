import AppKit
import SwiftTerm
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class CodexBackgroundTerminalTests: XCTestCase {
  private func fixture() throws -> WorkspaceStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("background-terminals-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    var task = WorkspaceTask(id: "task", project: root.path, title: "Task", runIDs: ["run"])
    task.codexThreadID = "thread"
    store.library.tasks = [task]
    store.library.chatRuns = [run("run", turn: "turn", project: root.path)]
    store.selection = "run"; store.project = root
    return store
  }
  private func run(_ id: String, turn: String, project: String) -> AgentRun {
    .init(id: id, kind: "chat", project: project, status: "running", createdAt: 0, updatedAt: 0,
      request: .object(["api_protocol": .string(ModelAPIProtocol.codexResponses.rawValue)]),
      result: .object(["codex_thread_id": .string("thread"), "codex_turn_id": .string(turn)]))
  }
  private func begin(_ turn: String = "turn", call: String = "call") -> JSONValue {
    .object(["type": .string("exec_command_begin"), "turn_id": .string(turn), "call_id": .string(call),
      "process_id": .string("core-process"), "command": .array([.string("/bin/zsh"), .string("-lc"), .string("sleep 30")])])
  }
  private func delta(_ bytes: Data, call: String = "call") -> JSONValue {
    .object(["type": .string("exec_command_output_delta"), "call_id": .string(call), "chunk": .string(bytes.base64EncodedString())])
  }
  private func finishModel(_ store: WorkspaceStore, id: String = "run", status: String = "succeeded") throws {
    let current = try XCTUnwrap(store.library.chatRuns.first { $0.id == id })
    store.replaceChat(current, status: status, response: "reply")
  }

  func testLateBytesAndCompletionStayWithOriginalTurnAndRejectUnknownIdentity() throws {
    let store = try fixture(); defer { store.workspace.browser.shutdown() }
    store.recordCodexRuntimeCommand(taskID: "task", threadID: "wrong", event: begin())
    store.recordCodexRuntimeCommand(taskID: "task", threadID: "thread", event: begin("unknown"))
    XCTAssertTrue(store.codexBackgroundTerminals.isEmpty)
    store.recordCodexRuntimeCommand(taskID: "task", threadID: "thread", event: begin())
    let id = try XCTUnwrap(store.codexBackgroundTerminals.keys.first)
    XCTAssertTrue(store.backgroundTerminals(taskID: "task").isEmpty, "Current model turn has no background summary row")
    try finishModel(store, status: "cancelled")
    store.library.tasks[0].runIDs.append("next")
    store.library.chatRuns.append(run("next", turn: "next-turn", project: store.dataRoot.path))
    store.recordCodexRuntimeCommand(taskID: "task", threadID: "thread", event: delta(Data([0xE4])))
    store.recordCodexRuntimeCommand(taskID: "task", threadID: "thread", event: delta(Data([0xBD, 0xA0])))
    XCTAssertEqual(store.backgroundTerminalDocument(id, taskID: "task")?.output, "你")
    XCTAssertEqual(store.library.chatRuns[0].toolExecutions.first?.output, "你")
    XCTAssertTrue(store.library.chatRuns[1].toolExecutions.isEmpty)
    XCTAssertNil(store.backgroundTerminalDocument(id, taskID: "other"))
    XCTAssertEqual(store.backgroundTerminals(taskID: "task").count, 1)
    store.recordCodexRuntimeCommand(taskID: "task", threadID: "thread", event: .object([
      "type": .string("exec_command_end"), "turn_id": .string("turn"), "call_id": .string("call"),
      "status": .string("failed"), "aggregated_output": .string("你\nfailed"), "exit_code": .number(3)]))
    XCTAssertTrue(store.backgroundTerminals(taskID: "task").isEmpty)
    XCTAssertEqual(store.library.chatRuns[0].status, "cancelled")
    XCTAssertEqual(store.library.chatRuns[0].toolExecutions.first?.status, .failed)
    XCTAssertEqual(store.library.chatRuns[1].status, "running")
  }

  func testAmbiguousCallIDCannotRouteUnscopedOutputAcrossTurns() throws {
    let store = try fixture(); defer { store.workspace.browser.shutdown() }
    store.recordCodexRuntimeCommand(taskID: "task", threadID: "thread", event: begin())
    try finishModel(store)
    store.library.tasks[0].runIDs.append("next")
    store.library.chatRuns.append(run("next", turn: "next-turn", project: store.dataRoot.path))
    store.recordCodexRuntimeCommand(taskID: "task", threadID: "thread", event: begin("next-turn"))
    XCTAssertEqual(store.codexBackgroundTerminals.count, 2)
    store.recordCodexRuntimeCommand(taskID: "task", threadID: "thread", event: delta(Data("ambiguous".utf8)))
    XCTAssertTrue(store.codexBackgroundTerminals.values.allSatisfy { $0.bytes.isEmpty })
    store.disconnectBackgroundTerminals(taskID: "task", threadID: "wrong")
    XCTAssertTrue(store.codexBackgroundTerminals.values.allSatisfy(\.running))
    store.disconnectBackgroundTerminals(taskID: "task", threadID: "thread")
    XCTAssertTrue(store.backgroundTerminals(taskID: "task").isEmpty)
    XCTAssertTrue(store.library.chatRuns.allSatisfy { $0.toolExecutions.allSatisfy { $0.status == .cancelled } })
  }

  func testOutputTabsRestoreExactOwnerWithoutStartingShellAndKeepTaskWindowIndependent() throws {
    let store = try fixture(); defer { store.workspace.browser.shutdown() }
    store.recordCodexRuntimeCommand(taskID: "task", threadID: "thread", event: begin())
    let id = try XCTUnwrap(store.codexBackgroundTerminals.keys.first)
    store.recordCodexRuntimeCommand(taskID: "task", threadID: "thread", event: delta(Data("saved output".utf8)))
    try finishModel(store)
    XCTAssertTrue(store.openBackgroundTerminal(id))
    let tab = try XCTUnwrap(store.activeRightWorkspaceContentTab)
    XCTAssertEqual(tab, .backgroundTerminal(id, owner: "task"))
    XCTAssertNil(tab.terminalID)
    XCTAssertFalse(store.canMoveWorkspaceTab(tab.id, to: .bottom))
    XCTAssertNil(store.moveWorkspaceTab(tab.id, toOwner: "other"))
    store.closeWorkspaceTab(tab.id); store.reopenClosedWorkspaceTab()
    XCTAssertEqual(store.activeRightWorkspaceContentTab, tab)
    store.pinWorkspaceTab(tab.id)
    XCTAssertEqual(store.library.pinnedContentTabs.first?.kind, .backgroundTerminal)
    let saved = try XCTUnwrap(store.workspaceTabLayoutSnapshot.tabs.first)
    let restored = WorkspaceStore(dataRoot: store.dataRoot)
    defer { restored.workspace.browser.shutdown() }
    restored.library = store.library
    XCTAssertEqual(restored.materializeWorkspaceTab(saved, owner: "task"), tab)
    XCTAssertNil(restored.materializeWorkspaceTab(saved, owner: "other"))
    XCTAssertTrue(restored.codexBackgroundTerminals.isEmpty)
    XCTAssertEqual(restored.backgroundTerminalDocument(id, taskID: "task")?.output, "saved output")
    store.selection = "unrelated"
    let resources = TaskWindowResources(); defer { resources.shutdown() }
    resources.prepare("task", store: store)
    let tabs = try XCTUnwrap(resources.tasks["task"])
    XCTAssertTrue(tabs.openBackgroundTerminal(id))
    XCTAssertEqual(tabs.selected(.right), tab)
    XCTAssertEqual(store.selection, "unrelated")
    let layout = tabs.layoutSnapshot
    let other = TaskWindowResources(); defer { other.shutdown() }
    other.prepare("task", store: store)
    other.tasks["task"]?.restoreLayout(layout)
    XCTAssertEqual(other.tasks["task"]?.selected(.right), tab)
    XCTAssertEqual(tabs.title(tab), "sleep 30")
  }

  func testCleanupFailureKeepsRowsAndReportsError() async throws {
    let store = try fixture(); defer { store.workspace.browser.shutdown() }
    store.recordCodexRuntimeCommand(taskID: "task", threadID: "thread", event: begin())
    try finishModel(store)
    let id = try XCTUnwrap(store.codexBackgroundTerminals.keys.first)
    await store.cleanBackgroundTerminals(taskID: "task", selectedID: id)
    XCTAssertNil(store.backgroundTerminalCleanup["task"])
    XCTAssertEqual(store.backgroundTerminals(taskID: "task").count, 1)
    XCTAssertEqual(store.notices.items.first?.title, "无法停止后台终端")
    XCTAssertEqual(store.notices.items.first?.level, .error)
    XCTAssertNil(store.notices.items.first?.taskID, "A cleanup error does not navigate to another window")
    let resources = TaskWindowResources()
    defer { resources.shutdown() }
    store.notices.completeAndDismiss("background-terminal-clean:task")
    await store.cleanBackgroundTerminals(taskID: "task", selectedID: id, notices: resources.notices)
    XCTAssertTrue(store.notices.items.isEmpty)
    XCTAssertEqual(resources.notices.items.first?.title, "无法停止后台终端")
    XCTAssertTrue(WorkspaceNoticesView(store: store, notices: resources.notices).notices === resources.notices)
    XCTAssertEqual(store.backgroundTerminals(taskID: "task").count, 1)
  }

  func testIdleStopIsAvailableWithoutTurnAndFailureDoesNotUseRowFeedback() async throws {
    let store = try fixture(); defer { store.workspace.browser.shutdown() }
    store.recordCodexRuntimeCommand(taskID: "task", threadID: "thread", event: begin())
    try finishModel(store)
    XCTAssertTrue(store.commandEnabled("stop"))
    XCTAssertNotNil(store.stopTarget(taskID: "task"))
    XCTAssertNil(store.stopTarget(taskID: "missing"))
    store.presentedOverlay = .taskSearch
    XCTAssertFalse(store.commandEnabled("stop"))
    store.presentedOverlay = nil
    await store.cancel(taskID: "task")
    XCTAssertTrue(store.notices.items.isEmpty)
    XCTAssertNil(store.error)
    XCTAssertTrue(store.backgroundTerminalCleanup.isEmpty)
    XCTAssertTrue(store.backgroundTerminalCleanupRequests.isEmpty)
    XCTAssertEqual(store.backgroundTerminals(taskID: "task").count, 1)
    store.disconnectBackgroundTerminals(taskID: "task")
    XCTAssertFalse(store.commandEnabled("stop"))
  }

  func testCapturedStopCancelsOriginalRunAndPausesGoalBeforeCancellation() async throws {
    let store = try fixture(); defer { store.workspace.browser.shutdown() }
    store.library.tasks.append(WorkspaceTask(id: "peer", project: store.dataRoot.path, title: "Peer", runIDs: ["peer-run"]))
    store.recordCodexRuntimeCommand(taskID: "task", threadID: "thread", event: begin())
    store.library.chatRuns.append(run("peer-run", turn: "peer-turn", project: store.dataRoot.path))
    store.library.goalSessions["task"] = .init(definition: .init(objective: "Goal", successCriteria: ["Done"]))
    let original = Task { _ = try? await Task.sleep(for: .seconds(30)) }
    let peer = Task { _ = try? await Task.sleep(for: .seconds(30)) }
    store.installModelTask(original, runID: "run"); store.installModelTask(peer, runID: "peer-run")
    defer { original.cancel(); peer.cancel(); store.removeModelTask(runID: "run"); store.removeModelTask(runID: "peer-run") }
    let stop = try XCTUnwrap(store.requestStop())
    store.selection = "peer-run"
    await stop.value
    XCTAssertTrue(original.isCancelled)
    XCTAssertFalse(peer.isCancelled)
    XCTAssertTrue(store.codexBackgroundTerminals.values.allSatisfy { $0.running && !$0.cleanupRequested },
      "Interrupting an active turn must not clean unified exec background processes")
    XCTAssertEqual(store.library.goalSessions["task"]?.status, .paused)
    let persisted = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(persisted.goalSessions["task"]?.status, .paused)
    XCTAssertEqual(store.selection, "peer-run")
  }

  func testStaleRunStopNeverRetargetsNextRunOrItsBackgroundTerminals() async throws {
    let store = try fixture(); defer { store.workspace.browser.shutdown() }
    let target = try XCTUnwrap(store.stopTarget())
    store.recordCodexRuntimeCommand(taskID: "task", threadID: "thread", event: begin())
    try finishModel(store)
    store.library.tasks[0].runIDs.append("next")
    store.library.chatRuns.append(run("next", turn: "next-turn", project: store.dataRoot.path))
    let next = Task { _ = try? await Task.sleep(for: .seconds(30)) }
    store.installModelTask(next, runID: "next")
    defer { next.cancel(); store.removeModelTask(runID: "next") }
    await store.performStop(target)
    XCTAssertFalse(next.isCancelled)
    XCTAssertEqual(store.backgroundTerminals(taskID: "task").count, 1)
    XCTAssertTrue(store.notices.items.isEmpty)
  }

  func testCapturedIdleStopDoesNotCleanNewTurnOrChangedThread() async throws {
    let store = try fixture(); defer { store.workspace.browser.shutdown() }
    store.recordCodexRuntimeCommand(taskID: "task", threadID: "thread", event: begin())
    try finishModel(store)
    let idle = try XCTUnwrap(store.stopTarget())
    store.library.tasks[0].runIDs.append("next")
    store.library.chatRuns.append(run("next", turn: "next-turn", project: store.dataRoot.path))
    store.library.goalSessions["task"] = .init(definition: .init(objective: "Goal", successCriteria: ["Done"]))
    await store.performStop(idle)
    XCTAssertEqual(store.library.goalSessions["task"]?.status, .active)
    try finishModel(store, id: "next")
    let id = try XCTUnwrap(store.codexBackgroundTerminals.keys.first)
    let old = try XCTUnwrap(store.codexBackgroundTerminals[id])
    store.codexBackgroundTerminals[id] = .init(id: id, taskID: old.taskID, runID: old.runID,
      threadID: "replacement", turnID: old.turnID, callID: old.callID, processID: old.processID,
      command: old.command, bytes: old.bytes)
    await store.performStop(idle)
    XCTAssertEqual(store.library.goalSessions["task"]?.status, .active)
    XCTAssertFalse(store.codexBackgroundTerminals[id]?.cleanupRequested == true)
  }

  func testCapturedIdleStopRejectsReplacedTaskThreadEvenIfOldRuntimeEntryRemains() async throws {
    let store = try fixture(); defer { store.workspace.browser.shutdown() }
    store.recordCodexRuntimeCommand(taskID: "task", threadID: "thread", event: begin())
    try finishModel(store)
    let target = try XCTUnwrap(store.stopTarget())
    store.library.tasks[0].codexThreadID = "replacement"
    store.library.goalSessions["task"] = .init(definition: .init(objective: "Goal", successCriteria: ["Done"]))
    XCTAssertNil(store.stopTarget(taskID: "task"))
    await store.performStop(target)
    XCTAssertEqual(store.library.goalSessions["task"]?.status, .active)
    XCTAssertTrue(store.codexBackgroundTerminals.values.allSatisfy { $0.running && !$0.cleanupRequested })
  }

  func testIdleStopKeyboardContextOwnsTaskAndPreservesBrowserFocusFilter() async throws {
    let store = try fixture(); defer { store.workspace.browser.shutdown() }
    store.recordCodexRuntimeCommand(taskID: "task", threadID: "thread", event: begin())
    try finishModel(store)
    var browserFocused = false
    var stop: Task<Void, Never>?
    let context = TaskWindowCommandContext(enabled: store.stopTarget(taskID: "task") == nil ? [] : ["stop"],
      perform: { _ in stop = store.requestStop(taskID: "task") }, keyboardAllowed: { _ in !browserFocused })
    XCTAssertEqual(context.command(for: ShortcutBinding("⌘."), shortcuts: store.shortcuts), "stop")
    browserFocused = true
    XCTAssertNil(context.command(for: ShortcutBinding("⌘."), shortcuts: store.shortcuts))
    XCTAssertTrue(context.execute("stop"), "A menu action remains available independently of browser keyboard focus")
    await stop?.value
    XCTAssertTrue(store.notices.items.isEmpty)
    XCTAssertTrue(store.backgroundTerminalCleanup.isEmpty)
    XCTAssertEqual(store.backgroundTerminals(taskID: "task").count, 1)
  }

  func testTaskStopDoesNotFallBackToAnotherLocalRunAndMainPrefersOwnedBackground() throws {
    let store = try fixture(); defer { store.workspace.browser.shutdown() }
    store.recordCodexRuntimeCommand(taskID: "task", threadID: "thread", event: begin())
    try finishModel(store)
    let expected = try XCTUnwrap(store.stopTarget(taskID: "task"))
    let local = AgentRun(id: "build", kind: "build", project: store.dataRoot.path,
      status: "running", createdAt: 0, updatedAt: 0, request: .null, result: nil)
    store.runs.append(local)
    XCTAssertEqual(store.stopTarget(), expected)
    XCTAssertNil(store.stopTarget(taskID: "missing"))
    store.backgroundTerminalCleanupRequests.insert("task")
    XCTAssertNil(store.stopTarget(), "Pending task cleanup must not redirect Stop to an unrelated build")
    XCTAssertNil(store.stopTarget(taskID: "task"))
    store.backgroundTerminalCleanupRequests.remove("task")
    store.disconnectBackgroundTerminals(taskID: "task")
    XCTAssertNil(store.stopTarget(taskID: "task"))
    XCTAssertEqual(store.stopTarget(), .run(runID: "build", taskID: nil))
  }

  func testForkedHistoricalExecutionDoesNotReadOriginalTasksLiveOutput() throws {
    let store = try fixture(); defer { store.workspace.browser.shutdown() }
    store.recordCodexRuntimeCommand(taskID: "task", threadID: "thread", event: begin())
    let id = try XCTUnwrap(store.codexBackgroundTerminals.keys.first)
    store.recordCodexRuntimeCommand(taskID: "task", threadID: "thread", event: delta(Data("snapshot".utf8)))
    try finishModel(store)
    let original = try XCTUnwrap(store.library.chatRuns.first)
    let fork = AgentRun(id: "fork-run", kind: original.kind, project: original.project,
      status: original.status, createdAt: original.createdAt, updatedAt: original.updatedAt,
      request: original.request, result: original.result)
    store.library.tasks.append(WorkspaceTask(id: "fork", project: original.project, title: "Fork", runIDs: [fork.id]))
    store.library.chatRuns.append(fork)
    store.recordCodexRuntimeCommand(taskID: "task", threadID: "thread", event: delta(Data(" live-only".utf8)))
    XCTAssertEqual(store.backgroundTerminalDocument(id, taskID: "task")?.output, "snapshot live-only")
    XCTAssertEqual(store.backgroundTerminalDocument(id, taskID: "fork")?.output, "snapshot")
    XCTAssertTrue(store.backgroundTerminals(taskID: "fork").isEmpty)
  }

  func testBackgroundRowsKeepExecutionOrderAndRestartKeepsCompletedReplyAndOutput() throws {
    let store = try fixture(); defer { store.workspace.browser.shutdown() }
    store.recordCodexRuntimeCommand(taskID: "task", threadID: "thread", event: begin())
    store.recordCodexRuntimeCommand(taskID: "task", threadID: "thread", event: begin(call: "second"))
    store.recordCodexRuntimeCommand(taskID: "task", threadID: "thread", event: delta(Data("retained".utf8)))
    try finishModel(store)
    let current = try XCTUnwrap(store.library.chatRuns.first)
    var executions = current.toolExecutions
    for (index, uuid) in ["FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", "00000000-0000-0000-0000-000000000001"].enumerated() {
      let entry = try XCTUnwrap(store.codexBackgroundTerminals.removeValue(forKey: executions[index].id))
      let id = try XCTUnwrap(UUID(uuidString: uuid))
      executions[index].id = id
      store.codexBackgroundTerminals[id] = .init(id: id, taskID: entry.taskID, runID: entry.runID,
        threadID: entry.threadID, turnID: entry.turnID, callID: entry.callID, processID: entry.processID,
        command: entry.command, bytes: entry.bytes)
    }
    store.replaceChat(current, status: current.status, response: "reply", toolExecutions: executions)
    XCTAssertEqual(store.backgroundTerminals(taskID: "task").map(\.id), executions.map(\.id))
    let restored = WorkspaceStore(dataRoot: store.dataRoot)
    defer { restored.workspace.browser.shutdown() }
    restored.library = store.library
    restored.restoreInterruptedChats()
    XCTAssertEqual(restored.library.chatRuns.first?.status, "succeeded")
    XCTAssertEqual(restored.library.chatRuns.first?.result?["response"].text, "reply")
    XCTAssertEqual(restored.library.chatRuns.first?.toolExecutions.first?.status, .cancelled)
    XCTAssertEqual(restored.backgroundTerminalDocument(executions[0].id, taskID: "task")?.output, "retained")
    XCTAssertTrue(restored.backgroundTerminals(taskID: "task").isEmpty)
  }

  private final class OutputTestWindow: NSWindow {
    var active = true
    override var isKeyWindow: Bool { active }
  }

  func testOutputFocusWaitsForOwnerWindowAndModalPermissionAndDoesNotStealOnOutputUpdates() async {
    _ = NSApplication.shared
    let window = OutputTestWindow(contentRect: .init(x: 0, y: 0, width: 500, height: 200),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSView(frame: .init(x: 0, y: 0, width: 500, height: 200))
    let view = BackgroundOutputTerminalView(frame: .init(x: 0, y: 0, width: 500, height: 200))
    let renderer = BackgroundTerminalOutputHost.Coordinator()
    defer { renderer.detach(); window.close() }
    var allowed = false
    renderer.updateInteraction(view, focused: true, canFocus: { allowed }, openLink: { _ in })
    await flush()
    XCTAssertFalse(renderer.focusHandled)
    window.contentView?.addSubview(view)
    await flush()
    XCTAssertFalse(window.firstResponder === view)
    allowed = true; window.active = false
    renderer.scheduleFocus(); await flush()
    XCTAssertFalse(renderer.focusHandled)
    window.active = true
    renderer.scheduleFocus(); await flush()
    XCTAssertTrue(window.firstResponder === view)
    XCTAssertTrue(renderer.focusHandled)
    _ = window.makeFirstResponder(nil)
    renderer.update(view, output: "next output")
    renderer.updateInteraction(view, focused: true, canFocus: { allowed }, openLink: { _ in })
    await flush()
    XCTAssertFalse(window.firstResponder === view)
    renderer.updateInteraction(view, focused: false, canFocus: { true }, openLink: { _ in })
    renderer.updateInteraction(view, focused: true, canFocus: { true }, openLink: { _ in })
    renderer.detach(); await flush()
    XCTAssertFalse(window.firstResponder === view)
    XCTAssertNil(view.outputCoordinator)
  }

  func testOutputLinksUseOwningSurfaceCallbackAndDetachCancelsRouting() {
    let view = BackgroundOutputTerminalView(frame: .init(x: 0, y: 0, width: 500, height: 200))
    let renderer = BackgroundTerminalOutputHost.Coordinator()
    var opened: [URL] = []
    renderer.updateInteraction(view, focused: false, canFocus: { false }, openLink: { opened.append($0) })
    renderer.requestOpenLink(source: view, link: "https://example.com/path", params: [:])
    XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com/path"])
    renderer.detach()
    renderer.requestOpenLink(source: view, link: "https://example.com/late", params: [:])
    XCTAssertEqual(opened.count, 1)
  }

  private func flush() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
  }

  func testBackgroundSummaryAndOutputRenderWithinOwnerAtWideAndNarrowSizes() async throws {
    let store = try fixture(); defer { store.workspace.browser.shutdown() }
    store.recordCodexRuntimeCommand(taskID: "task", threadID: "thread", event: begin())
    let id = try XCTUnwrap(store.codexBackgroundTerminals.keys.first)
    store.recordCodexRuntimeCommand(taskID: "task", threadID: "thread", event: delta(Data("\u{1B}[31mRED\u{1B}[0m\n你好\nlate output".utf8)))
    try finishModel(store)
    let document = try XCTUnwrap(store.backgroundTerminalDocument(id, taskID: "task"))
    var appearance = AppearancePreferences(); appearance.codeSize = 16
    _ = NSApplication.shared
    for width: CGFloat in [760, 320] {
      let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: 380),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 0) {
        BackgroundTerminalSummarySection(terminals: store.backgroundTerminals(taskID: "task"),
          cleaning: nil, open: { _ in }, clean: { _ in }).padding(16)
        Divider()
        BackgroundTerminalOutputView(document: document)
      }.environment(\.appAppearance, appearance))
      window.contentView = host
      try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
      func terminals(_ view: NSView) -> [BackgroundOutputTerminalView] {
        (view as? BackgroundOutputTerminalView).map { [$0] } ?? view.subviews.flatMap(terminals)
      }
      let terminal = try XCTUnwrap(terminals(host).first)
      XCTAssertTrue(terminal.window === window)
      XCTAssertGreaterThan(terminal.bounds.width, 100)
      XCTAssertLessThanOrEqual(terminal.bounds.width, width - 12)
      XCTAssertEqual(terminal.font.pointSize, 16)
      XCTAssertNil(window.attachedSheet)
      XCTAssertFalse(window.isVisible, "This is hidden native rendering, not foreground acceptance")
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      if let directory = ProcessInfo.processInfo.environment["SHIPIOS_BACKGROUND_RENDER_DIRECTORY"] {
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
          to: URL(fileURLWithPath: directory).appendingPathComponent("background-\(Int(width)).png"), options: .atomic)
      }
      window.close()
    }
  }

  func testReadOnlyNativeOutputRendersANSIAppendsAndReplacesWithoutProcessInput() throws {
    let view = BackgroundOutputTerminalView(frame: NSRect(x: 0, y: 0, width: 500, height: 200), font: nil,
      options: TerminalOptions(convertEol: true))
    let renderer = BackgroundTerminalOutputHost.Coordinator()
    view.terminalDelegate = renderer
    renderer.update(view, output: "\u{1B}[31mRED\u{1B}[0m\n你")
    XCTAssertTrue(view.getTerminal().getLine(row: 0)?.translateToString().contains("RED") == true)
    renderer.update(view, output: "\u{1B}[31mRED\u{1B}[0m\n你好")
    XCTAssertEqual(view.getTerminal().getCharacter(col: 0, row: 1), "你")
    XCTAssertEqual(view.getTerminal().getCharacter(col: 2, row: 1), "好")
    XCTAssertEqual(view.getTerminal().getLine(row: 1)?.translateToString(trimRight: true,
      skipNullCellsFollowingWide: true), "你好")
    renderer.send(source: view, data: Array("touch should-not-execute".utf8)[...])
    renderer.update(view, output: "replacement")
    XCTAssertTrue(view.getTerminal().getLine(row: 0)?.translateToString().contains("replacement") == true,
      "dimensions=\(view.getTerminal().getDims()), rows=\((0..<4).map { view.getTerminal().getLine(row: $0)?.translateToString() ?? "nil" })")
    XCTAssertFalse(view.getTerminal().getLine(row: 0)?.translateToString().contains("RED") == true)
  }

  func testSplitANSISequencesKeepTheirParserStateAndReplacementCancelsIncompleteOSC() {
    let view = BackgroundOutputTerminalView(frame: .init(x: 0, y: 0, width: 500, height: 200))
    let renderer = BackgroundTerminalOutputHost.Coordinator()
    renderer.update(view, output: "\u{1B}[3")
    renderer.update(view, output: "\u{1B}[31mRED")
    XCTAssertEqual(view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true), "RED")
    XCTAssertEqual(view.getTerminal().getCharData(col: 0, row: 0)?.attribute.fg, .ansi256(code: 1))
    renderer.update(view, output: "\u{1B}]8;;https://example.com/pending")
    renderer.update(view, output: "replacement")
    XCTAssertEqual(view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true), "replacement")
    XCTAssertEqual(view.getTerminal().getCharData(col: 0, row: 0)?.attribute.fg, .defaultColor)
  }

  func testRealBackgroundOutputAfterCompletedTurnAndDuringContinuationPersistsAndCleansPeer() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-background-\(UUID())")
    let project = root.appendingPathComponent("Project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = ["-u", URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/background_terminal_model_server.py").path]
    server.environment = ["BACKGROUND_GATE_ROOT": project.path]
    let output = Pipe(); server.standardOutput = output; server.standardError = FileHandle.nullDevice
    try server.run()
    defer { if server.isRunning { server.terminate(); server.waitUntilExit() }; try? FileManager.default.removeItem(at: root) }
    let port = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    _ = try XCTUnwrap(Int(port))
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: try AgentTestExecutable.url())
    await store.restore()
    var config = ModelConfiguration(); config.baseURL = "http://127.0.0.1:\(port)/v1"
    config.model = "gpt-5.4"; config.apiProtocol = .codexResponses; config.reasoning = "low"
    try store.saveModelConfiguration(config)
    store.notificationPreferences = .init(timing: .never)
    await store.open(project); XCTAssertTrue(store.connected, store.error ?? "")
    let firstStarted = await store.startChat("background-target")
    let first = try XCTUnwrap(firstStarted)
    await store.modelTask(runID: first)?.value
    let task = try XCTUnwrap(store.library.task(containing: first))
    XCTAssertEqual(store.library.chatRuns.first { $0.id == first }?.status, "succeeded")
    let terminal = try XCTUnwrap(store.backgroundTerminals(taskID: task.id).first)
    let pid = try XCTUnwrap(Int32(String(contentsOf: project.appendingPathComponent("target-pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    XCTAssertEqual(kill(pid, 0), 0)
    XCTAssertTrue(store.openBackgroundTerminal(terminal.id))
    let tab = try XCTUnwrap(store.activeRightWorkspaceContentTab)
    store.newTask()
    let peerStarted = await store.startChat("background-peer")
    let peer = try XCTUnwrap(peerStarted)
    await store.modelTask(runID: peer)?.value
    let peerTask = try XCTUnwrap(store.library.task(containing: peer))
    let peerTerminal = try XCTUnwrap(store.backgroundTerminals(taskID: peerTask.id).first)
    let peerPID = try XCTUnwrap(Int32(String(contentsOf: project.appendingPathComponent("peer-pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    let nextStarted = await store.startChat("hold-background-continuation", taskID: task.id)
    let next = try XCTUnwrap(nextStarted)
    try await eventually { FileManager.default.fileExists(atPath: project.appendingPathComponent("model-waiting").path) }
    try Data().write(to: project.appendingPathComponent("target-late-release"))
    try await eventually { store.backgroundTerminalDocument(terminal.id, taskID: task.id)?.output.contains("late-target") == true }
    XCTAssertTrue(store.library.chatRuns.first { $0.id == next }?.toolExecutions.isEmpty == true)
    XCTAssertFalse(store.backgroundTerminalDocument(peerTerminal.id, taskID: peerTask.id)?.output.contains("late-target") == true)
    try Data().write(to: project.appendingPathComponent("target-finish-release"))
    try await eventually { store.codexBackgroundTerminals[terminal.id]?.running == false }
    XCTAssertEqual(store.library.chatRuns.first { $0.id == first }?.toolExecutions.first?.status, .failed)
    XCTAssertEqual(store.library.chatRuns.first { $0.id == next }?.status, "running")
    try Data().write(to: project.appendingPathComponent("model-release"))
    await store.modelTask(runID: next)?.value
    XCTAssertEqual(store.library.chatRuns.first { $0.id == next }?.status, "succeeded")
    await store.cleanBackgroundTerminals(taskID: peerTask.id, selectedID: peerTerminal.id)
    try await eventually { kill(peerPID, 0) != 0 }
    XCTAssertTrue(store.backgroundTerminals(taskID: peerTask.id).isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("peer-finish-release").path))
    let text = try XCTUnwrap(store.backgroundTerminalDocument(terminal.id, taskID: task.id)?.output)
    await store.shutdown()
    let restored = WorkspaceStore(dataRoot: store.dataRoot, agentExecutable: try AgentTestExecutable.url())
    await restored.restore()
    XCTAssertEqual(restored.backgroundTerminalDocument(terminal.id, taskID: task.id)?.output, text)
    XCTAssertTrue(restored.codexBackgroundTerminals.isEmpty)
    XCTAssertEqual(restored.materializeWorkspaceTab(SavedWorkspaceTab(id: tab.id, kind: .backgroundTerminal,
      placement: .right, address: nil, committedURL: nil), owner: task.id), tab)
    await restored.shutdown()
  }
  func testRealIdleStopCommandUsesCapturedTaskAndLeavesPeerProcessAndRepliesIntact() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-idle-stop-\(UUID())")
    let project = root.appendingPathComponent("Project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = ["-u", URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/background_terminal_model_server.py").path]
    server.environment = ["BACKGROUND_GATE_ROOT": project.path]
    let output = Pipe(); server.standardOutput = output; server.standardError = FileHandle.nullDevice
    try server.run()
    defer { if server.isRunning { server.terminate(); server.waitUntilExit() }; try? FileManager.default.removeItem(at: root) }
    let port = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    _ = try XCTUnwrap(Int(port))
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: try AgentTestExecutable.url())
    await store.restore()
    var config = ModelConfiguration(); config.baseURL = "http://127.0.0.1:\(port)/v1"
    config.model = "gpt-5.4"; config.apiProtocol = .codexResponses; config.reasoning = "low"
    try store.saveModelConfiguration(config)
    store.notificationPreferences = .init(timing: .never)
    await store.open(project)
    let started = await store.startChat("background-target")
    let first = try XCTUnwrap(started)
    await store.modelTask(runID: first)?.value
    let task = try XCTUnwrap(store.library.task(containing: first))
    let terminal = try XCTUnwrap(store.backgroundTerminals(taskID: task.id).first)
    let pid = try XCTUnwrap(Int32(String(contentsOf: project.appendingPathComponent("target-pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    store.newTask()
    let peerStarted = await store.startChat("background-peer")
    let peer = try XCTUnwrap(peerStarted)
    await store.modelTask(runID: peer)?.value
    let peerTask = try XCTUnwrap(store.library.task(containing: peer))
    let peerPID = try XCTUnwrap(Int32(String(contentsOf: project.appendingPathComponent("peer-pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    XCTAssertEqual(kill(pid, 0), 0); XCTAssertEqual(kill(peerPID, 0), 0)
    store.selection = first
    XCTAssertTrue(store.commandEnabled("stop"))
    store.executeCommand("stop")
    store.selection = peer
    try await eventually { kill(pid, 0) != 0 }
    XCTAssertEqual(kill(peerPID, 0), 0)
    XCTAssertTrue(store.backgroundTerminals(taskID: task.id).isEmpty)
    XCTAssertEqual(store.backgroundTerminals(taskID: peerTask.id).count, 1)
    XCTAssertEqual(store.library.chatRuns.first { $0.id == first }?.status, "succeeded")
    XCTAssertEqual(store.library.chatRuns.first { $0.id == peer }?.status, "succeeded")
    XCTAssertEqual(store.library.chatRuns.first { $0.id == first }?.result?["response"].text, "Background fixture reply")
    XCTAssertTrue(store.backgroundTerminalDocument(terminal.id, taskID: task.id)?.output.contains("initial-target") == true)
    XCTAssertTrue(store.backgroundTerminalCleanup.isEmpty)
    XCTAssertTrue(store.notices.items.isEmpty)
    XCTAssertEqual(store.selection, peer)
    await store.cancel(taskID: peerTask.id)
    try await eventually { kill(peerPID, 0) != 0 }
    await store.shutdown()
  }

  private func eventually(_ predicate: () -> Bool) async throws {
    for _ in 0..<1500 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
    XCTFail("Expected native background terminal state was not observed")
    throw AgentFailure(message: "Background terminal test timed out")
  }
}
