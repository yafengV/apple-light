import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class CodexSubagentTests: XCTestCase {
  private let rootThread = "00000000-0000-4000-8000-000000000001"
  private let child = "00000000-0000-4000-8000-000000000002"
  private let otherRoot = "00000000-0000-4000-8000-000000000003"

  private func row(_ id: String, status: String = "running", loaded: Bool = true,
    name: String? = "Worker", preview: String? = nil) -> JSONValue {
    .object(["threadId": .string(id), "parentThreadId": .string(rootThread),
      "nickname": name.map(JSONValue.string) ?? .null, "role": .string("worker"),
      "depth": .number(1), "model": .string("fixture-model"), "reasoningEffort": .string("high"),
      "status": .string(status), "loaded": .bool(loaded), "preview": preview.map(JSONValue.string) ?? .null])
  }
  private func frame(_ rows: [JSONValue], id: String = UUID().uuidString, offset: Int = 0,
    total: Int? = nil, done: Bool = true, time: Int = 1) -> JSONValue {
    .object(["type": .string("shipios_subagent_snapshot"), "snapshotId": .string(id),
      "offset": .number(Double(offset)), "total": .number(Double(total ?? rows.count)),
      "done": .bool(done), "revision": .number(Double(time)),
      "observedAtMs": .number(Double(time)), "agents": .array(rows)])
  }
  private func fixture() throws -> WorkspaceStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("subagents-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    var task = WorkspaceTask(id: "task", project: root.path, title: "Parent", runIDs: ["run"])
    task.codexThreadID = rootThread
    store.library.tasks = [task]
    store.library.chatRuns = [.init(id: "run", kind: "chat", project: root.path, status: "succeeded",
      createdAt: 0, updatedAt: 0, request: .object([:]), result: .object(["response": .string("parent done")]))]
    store.selection = "run"; store.project = root
    return store
  }

  func testLargeSnapshotAppliesAtomicallyWithoutDroppingDescendants() throws {
    var assembler = CodexSubagentSnapshotAssembler()
    let rows = (0..<193).map { _ in row(UUID().uuidString) }, id = UUID().uuidString
    for offset in stride(from: 0, to: rows.count, by: 64) {
      let end = min(offset + 64, rows.count)
      let result = assembler.append(frame(Array(rows[offset..<end]), id: id,
        offset: offset, total: rows.count, done: end == rows.count), root: rootThread)
      if end == rows.count { XCTAssertEqual(result?.map(\.threadID), rows.map { $0["threadId"].text! }) }
      else { XCTAssertNil(result, "Incomplete snapshots cannot clear current active state") }
    }
    XCTAssertEqual(assembler.append(frame([]), root: rootThread), [])
  }

  func testMissingMixedRootDuplicateAndMalformedChunksNeverReplaceLiveState() throws {
    let store = try fixture(); defer { store.workspace.browser.shutdown() }
    store.recordSubagentSnapshot(taskID: "task", threadID: rootThread, event: frame([row(child)]))
    let before = store.subagents(taskID: "task")
    let id = UUID().uuidString
    for invalid in [frame([row(child), row(child)]), frame([row("invalid")]),
      frame([row(child, loaded: false)]), frame([row(child, status: "unknown")]),
      frame([row(child)], id: id, offset: 1, total: 2), frame([], total: 1, done: false)] {
      store.recordSubagentSnapshot(taskID: "task", threadID: rootThread, event: invalid)
      XCTAssertEqual(store.subagents(taskID: "task"), before)
    }
    var assembler = CodexSubagentSnapshotAssembler()
    XCTAssertNil(assembler.append(frame([row(child)], id: id, total: 2, done: false), root: rootThread))
    XCTAssertNil(assembler.append(frame([row(UUID().uuidString)], id: id, offset: 1, total: 2), root: otherRoot))
    XCTAssertNil(assembler.append(frame([row(child)], id: UUID().uuidString, offset: 1, total: 2), root: rootThread))
  }

  func testIdleParentLateStatusesStayWithOwnerAndRejectOlderSnapshots() throws {
    let store = try fixture(); defer { store.workspace.browser.shutdown() }
    var peer = WorkspaceTask(id: "peer", project: store.dataRoot.path, title: "Peer", runIDs: [])
    peer.codexThreadID = otherRoot; store.library.tasks.append(peer)
    store.recordSubagentSnapshot(taskID: "task", threadID: rootThread, event: frame([row(child)], time: 3))
    XCTAssertEqual(store.activeSubagents(taskID: "task").count, 1)
    XCTAssertTrue(store.activeSubagents(taskID: "peer").isEmpty)
    XCTAssertEqual(store.library.chatRuns[0].status, "succeeded")
    for (task, root) in [("peer", rootThread), ("task", otherRoot), ("missing", rootThread)] {
      store.recordSubagentSnapshot(taskID: task, threadID: root, event: frame([]))
    }
    store.recordSubagentSnapshot(taskID: "task", threadID: rootThread,
      event: frame([row(child, status: "completed", preview: "Child finished")], time: 4))
    store.recordSubagentSnapshot(taskID: "task", threadID: rootThread, event: frame([row(child)], time: 2))
    XCTAssertTrue(store.activeSubagents(taskID: "task").isEmpty)
    XCTAssertEqual(store.subagents(taskID: "task").first?.preview, "Child finished")
    store.recordSubagentSnapshot(taskID: "task", threadID: rootThread, event: frame([], time: 2))
    XCTAssertEqual(store.subagents(taskID: "task").count, 1, "Older empty snapshots cannot erase live history")
    XCTAssertEqual(store.library.chatRuns[0].result?["response"].text, "parent done")
  }

  func testColdHistoryPreservesMetadataAndRestartNeverRestoresLiveProcesses() throws {
    let store = try fixture(); defer { store.workspace.browser.shutdown() }
    let active = UUID().uuidString
    store.recordSubagentSnapshot(taskID: "task", threadID: rootThread, event: frame([
      row(child, status: "completed", preview: "Original answer"), row(active)], time: 3))
    let cold: JSONValue = .object(["threadId": .string(child), "status": .string("notLoaded"), "loaded": .bool(false)])
    store.recordSubagentSnapshot(taskID: "task", threadID: rootThread, event: frame([cold, row(active)], time: 4))
    XCTAssertEqual(store.subagents(taskID: "task").first?.status, .completed)
    XCTAssertEqual(store.subagents(taskID: "task").first?.displayName, "Worker")
    store.saveLibrary()
    let restored = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    let agents = try XCTUnwrap(restored.tasks.first?.codexSubagents)
    XCTAssertEqual(agents.first?.preview, "Original answer")
    XCTAssertFalse(agents.contains(where: \.working))
    XCTAssertEqual(agents.last?.status, .notLoaded)
    var legacy = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(store.library.tasks[0]))
    if case .object(var fields) = legacy { fields.removeValue(forKey: "codexSubagents"); legacy = .object(fields) }
    XCTAssertNil(try legacy.decode(WorkspaceTask.self).codexSubagents)
    store.disconnectSubagents(taskID: "peer")
    XCTAssertEqual(store.activeSubagents(taskID: "task").count, 1)
    store.disconnectSubagents(taskID: "task")
    XCTAssertTrue(store.activeSubagents(taskID: "task").isEmpty)
  }

  func testIdleStopCapturesTaskAndRejectsNewTurnOrReplacementThread() async throws {
    let store = try fixture(); defer { store.workspace.browser.shutdown() }
    store.recordSubagentSnapshot(taskID: "task", threadID: rootThread, event: frame([row(child)]))
    let target = try XCTUnwrap(store.stopTarget(taskID: "task"))
    XCTAssertEqual(target, .descendants(taskID: "task", threadID: rootThread, childIDs: [child]))
    XCTAssertTrue(store.commandEnabled("stop"))
    store.selection = "other"
    XCTAssertFalse(store.openSubagents(taskID: "task"), "A stale summary cannot open another task's panel")
    XCTAssertNil(store.stopTarget(taskID: "other"))
    await store.performStop(target)
    XCTAssertTrue(store.notices.items.isEmpty); XCTAssertNil(store.error)
    XCTAssertEqual(store.activeSubagents(taskID: "task").count, 1, "Submission failure cannot pretend the child ended")
    store.library.chatRuns.append(.init(id: "new", kind: "chat", project: store.dataRoot.path,
      status: "running", createdAt: 0, updatedAt: 0, request: .object([:]), result: nil))
    store.library.tasks[0].runIDs.append("new")
    XCTAssertEqual(store.stopTarget(taskID: "task"), .run(runID: "new", taskID: "task"))
    await store.performStop(target)
    XCTAssertEqual(store.library.chatRuns.last?.status, "running")
    store.recordCodexThreadID(taskID: "task", threadID: otherRoot)
    XCTAssertTrue(store.activeSubagents(taskID: "task").isEmpty)
    await store.performStop(target)
    XCTAssertEqual(store.library.tasks[0].codexThreadID, otherRoot)
  }

  func testPanelTabsPinReopenRestoreAndKeepTaskWindowOwnership() throws {
    let store = try fixture(); defer { store.workspace.browser.shutdown() }
    XCTAssertFalse(store.openSubagents(in: .bottom))
    XCTAssertTrue(store.openSubagents())
    let tab = try XCTUnwrap(store.activeRightWorkspaceContentTab)
    XCTAssertEqual(tab, .subagents(owner: "task")); XCTAssertNil(tab.terminalID)
    XCTAssertFalse(store.canMoveWorkspaceTab(tab.id, to: .bottom))
    XCTAssertNil(store.moveWorkspaceTab(tab.id, toOwner: "peer"))
    store.pinWorkspaceTab(tab.id)
    XCTAssertEqual(store.library.pinnedContentTabs.first?.kind, .subagents)
    let layout = try XCTUnwrap(store.workspaceTabLayoutSnapshot.tabs.first)
    store.closeWorkspaceTab(tab.id); store.reopenClosedWorkspaceTab()
    XCTAssertEqual(store.activeRightWorkspaceContentTab, tab)
    let restored = WorkspaceStore(dataRoot: store.dataRoot); defer { restored.workspace.browser.shutdown() }
    restored.library = store.library
    XCTAssertEqual(restored.materializeWorkspaceTab(layout, owner: "task"), tab)
    XCTAssertNil(restored.materializeWorkspaceTab(layout, owner: "peer"))
    store.selection = "other"
    let resources = TaskWindowResources(); defer { resources.shutdown() }
    resources.prepare("task", store: store)
    let tabs = try XCTUnwrap(resources.tasks["task"])
    XCTAssertTrue(tabs.openSubagents()); XCTAssertEqual(tabs.selected(.right), tab)
    XCTAssertEqual(store.selection, "other")
    let snapshot = tabs.layoutSnapshot; tabs.close(tab.id); tabs.restoreLayout(snapshot)
    XCTAssertEqual(tabs.selected(.right), tab)
  }

  func testNativeOverviewRendersLongAndEmptyStatesAtNarrowAndWideSizes() throws {
    _ = NSApplication.shared
    var assembler = CodexSubagentSnapshotAssembler()
    let rows = try XCTUnwrap(assembler.append(frame((0..<24).map { i in
      row(UUID().uuidString, status: i < 12 ? "running" : "completed",
        name: String(repeating: "中文子任务名称", count: 20), preview: String(repeating: "long answer ", count: 80))
    }), root: rootThread))
    for width in [360, 760] {
      for agents in [rows, []] {
        let view = NSHostingView(rootView: SubagentsPanelView(agents: agents))
        view.frame = .init(x: 0, y: 0, width: width, height: 520)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.frame.width, CGFloat(width))
        if let directory = ProcessInfo.processInfo.environment["SHIPIOS_SUBAGENT_RENDER_DIRECTORY"] {
          let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
          view.cacheDisplay(in: view.bounds, to: bitmap)
          try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
            URL(fileURLWithPath: directory).appendingPathComponent("subagents-\(width)-\(agents.count).png"))
        }
        window.close()
      }
    }
  }
}
