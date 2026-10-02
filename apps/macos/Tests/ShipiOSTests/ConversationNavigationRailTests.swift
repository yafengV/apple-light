import SwiftUI
import XCTest

@testable import ShipiOS

final class ConversationNavigationRailTests: XCTestCase {
  private final class StubCapture: SystemAudioCapture, @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    func recordStart() { lock.lock(); starts += 1; lock.unlock() }
    func stop() { lock.lock(); stops += 1; lock.unlock() }
    var counts: (Int, Int) {
      lock.lock()
      defer { lock.unlock() }
      return (starts, stops)
    }
  }

  func testSelectionFollowsVisiblePromptAndScrubBounds() {
    let ids = ["first", "second", "third"]
    XCTAssertEqual(ConversationRailSelection.visibleIDs(positions: [
      "first": CGRect(x: 0, y: -100, width: 100, height: 116),
      "second": CGRect(x: 0, y: 90, width: 100, height: 60),
      "third": CGRect(x: 0, y: 420, width: 100, height: 60),
    ], orderedIDs: ids, viewportHeight: 300), ["second"])
    XCTAssertEqual(ConversationRailSelection.visibleIDs(positions: [
      "first": CGRect(x: 0, y: -10, width: 100, height: 50),
      "third": CGRect(x: 0, y: 200, width: 100, height: 50),
    ], orderedIDs: ids, viewportHeight: 300), Set(ids))
    XCTAssertTrue(ConversationRailSelection.visibleIDs(positions: [:],
      orderedIDs: ids, viewportHeight: 300).isEmpty)
    XCTAssertEqual(ConversationRailSelection.scrubbedID(y: -20,
      orderedIDs: ["first", "second"]), "first")
    XCTAssertEqual(ConversationRailSelection.scrubbedID(y: 100,
      orderedIDs: ["first", "second"]), "second")
    XCTAssertNil(ConversationRailSelection.scrubbedID(y: 0, orderedIDs: []))
    XCTAssertNil(ConversationRailSelection.scrubNavigationTarget(startY: 5, y: 7,
      previousID: nil, orderedIDs: ids))
    XCTAssertEqual(ConversationRailSelection.scrubNavigationTarget(startY: 5, y: 16,
      previousID: "first", orderedIDs: ids), "second")
    XCTAssertNil(ConversationRailSelection.scrubNavigationTarget(startY: 5, y: 19,
      previousID: "second", orderedIDs: ids))
    XCTAssertEqual(ConversationRailSelection.scrubNavigationTarget(startY: 5, y: 4,
      previousID: "second", orderedIDs: ids), "first")
    XCTAssertEqual(ConversationNavigationRail.minimumItems, 4)
    XCTAssertEqual(ConversationRailSelection.audioLevel(index: 1, itemCount: 4,
      levels: [0, 0.1, 0.2, 0.9, 0.4, 0.3, 0.2, 0]), 0.9)
    XCTAssertEqual(ConversationRailSelection.audioLevel(index: 0, itemCount: 4,
      levels: []), 0)
  }

  func testSystemAudioSpectrumUsesPlaybackFrequencies() {
    let sampleRate = 48_000.0
    let silence = Array(repeating: Float(0), count: SystemAudioSpectrumAnalysis.sampleCount)
    XCTAssertEqual(SystemAudioSpectrumAnalysis.levels(samples: silence,
      sampleRate: sampleRate), Array(repeating: 0, count: 64))
    let oneKilohertz = (0..<SystemAudioSpectrumAnalysis.sampleCount).map { index in
      Float(0.5 * sin(2 * .pi * 1_000 * Double(index) / sampleRate))
    }
    let levels = SystemAudioSpectrumAnalysis.levels(samples: oneKilohertz,
      sampleRate: sampleRate)
    XCTAssertEqual(levels.count, SystemAudioSpectrumAnalysis.bandCount)
    XCTAssertGreaterThan(levels.max() ?? 0, 0.7)
    XCTAssertGreaterThan(levels[30], levels[5])
    XCTAssertTrue(levels.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
  }

  func testRailPreviewFormatsBlockMarkdownAndKeepsTablesStructured() {
    let parts = ConversationRailPreviewDocument.parse("""
      # 结果

      - 第一项
      - 第二项

      | 名称 | 数量 |
      | --- | ---: |
      | 文件 | 2 |
      """)
    XCTAssertEqual(parts.count, 2)
    guard case .text(let text) = parts[0], case .table(let rows) = parts[1] else {
      return XCTFail("Expected formatted text followed by a table")
    }
    XCTAssertEqual(String(text.characters), "结果\n• 第一项\n• 第二项")
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows.map { $0.map { String($0.characters) } },
      [["名称", "数量"], ["文件", "2"]])
  }

  @MainActor func testNavigationFlashChangesTargetAndRespectsReducedMotion() async {
    let flash = ConversationRailFlash()
    flash.flash("first", reduceMotion: false)
    XCTAssertEqual(flash.id, "first")
    flash.flash("second", reduceMotion: false)
    XCTAssertEqual(flash.id, "second")
    flash.flash("third", reduceMotion: true)
    XCTAssertNil(flash.id)
    flash.flash("fourth", reduceMotion: false)
    flash.clear()
    XCTAssertNil(flash.id)
  }

  @MainActor func testVisualizerSharesAndStopsCaptureWithoutPersistingAudio() async throws {
    let stub = StubCapture()
    let visualizer = SystemAudioVisualizer(makeCapture: { _ in
      stub.recordStart()
      return stub
    })
    try await visualizer.ensureStarted()
    try await visualizer.ensureStarted()
    XCTAssertEqual(stub.counts.0, 1)
    XCTAssertTrue(visualizer.levels.isEmpty)
    visualizer.stop()
    XCTAssertEqual(stub.counts.1, 1)
    XCTAssertTrue(visualizer.levels.isEmpty)
  }

  @MainActor func testStoppingDuringStartupCleansUpBeforeRestart() async throws {
    let stub = StubCapture()
    let entered = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    let visualizer = SystemAudioVisualizer(makeCapture: { _ in
      stub.recordStart()
      if stub.counts.0 == 1 {
        entered.signal()
        _ = proceed.wait(timeout: .now() + 5)
      }
      return stub
    })
    let first = Task { try await visualizer.ensureStarted() }
    let began = await Task.detached { entered.wait(timeout: .now() + 5) }.value
    XCTAssertEqual(began, .success)
    visualizer.stop()
    proceed.signal()
    do {
      try await first.value
      XCTFail("Stopped startup must not become active")
    } catch is CancellationError {
      // The pending tap belongs to the old capture generation.
    }
    try await visualizer.ensureStarted()
    XCTAssertEqual(stub.counts.0, 2)
    XCTAssertEqual(stub.counts.1, 1)
    visualizer.stop()
    XCTAssertEqual(stub.counts.1, 2)
  }

  @MainActor func testVisualizerReportsCaptureFailure() async {
    let visualizer = SystemAudioVisualizer(makeCapture: { _ in
      throw AgentFailure(message: "capture-denied")
    })
    do {
      try await visualizer.ensureStarted()
      XCTFail("Expected capture failure")
    } catch {
      XCTAssertEqual(visualizer.error, "capture-denied")
      XCTAssertTrue(visualizer.levels.isEmpty)
    }
  }

  @MainActor func testPromptAndSteeredMessageBookmarksPersistAndDeleteWithTask() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-rail-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let message = QueuedMessage(taskID: "task", text: "后续问题")
    let steered = try JSONDecoder().decode(JSONValue.self,
      from: JSONEncoder().encode([message]))
    let run = AgentRun(id: "run", kind: "chat", project: "", status: "succeeded",
      createdAt: 1_000, updatedAt: 1_000, request: .null,
      result: .object([
        "codex_steered_messages": steered,
        "response_items": try ChatResponseItem.json([
          .message(id: UUID(), text: "首轮助手**回复**"), .user(message.id),
          .message(id: UUID(), text: "追加后的回复"),
        ]),
      ]))
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.library.chatRuns = [run]
    store.library.notes[run.id] = "首条问题"
    store.library.tasks = [WorkspaceTask(id: "task", project: "", title: "会话", runIDs: [run.id])]
    let items = store.conversationRailItems(for: [run])
    let steeredID = ConversationRailItem.steeredID(runID: run.id, messageID: message.id)
    XCTAssertEqual(items.map(\.id), [run.id, steeredID])
    XCTAssertEqual(items.map(\.title), ["首条问题", "后续问题"])
    XCTAssertEqual(items.map(\.preview), ["首轮助手**回复**", "追加后的回复"])
    XCTAssertTrue(store.setConversationBookmark(true, runID: run.id))
    XCTAssertTrue(store.setConversationBookmark(true, runID: steeredID))
    XCTAssertFalse(store.setConversationBookmark(true, runID: "unknown"))
    let restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(restored.bookmarkedRunIDs, [run.id, steeredID])
    XCTAssertEqual(store.conversationRailItems(for: [run]).map(\.bookmarked), [true, true])
    var deleted = restored
    deleted.tasks[0].archived = true
    XCTAssertEqual(deleted.deleteArchivedTasks(["task"]), ["run"])
    XCTAssertTrue(deleted.bookmarkedRunIDs.isEmpty)
    XCTAssertTrue(try JSONDecoder().decode(WorkspaceLibrary.self,
      from: Data("{}".utf8)).bookmarkedRunIDs.isEmpty)
  }

  @MainActor func testRunningLastTurnShowsPreviewLoadingUntilResponseArrives() {
    let store = WorkspaceStore(dataRoot: FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString))
    let running = AgentRun(id: "active", kind: "chat", project: "", status: "running",
      createdAt: 1_000, updatedAt: 1_000, request: .null, result: nil)
    store.library.notes[running.id] = "等待回复"
    let item = store.conversationRailItems(for: [running])[0]
    XCTAssertEqual(item.title, "等待回复")
    XCTAssertEqual(item.previewState, .loading)
    let finished = AgentRun(id: running.id, kind: "chat", project: "", status: "succeeded",
      createdAt: 1_000, updatedAt: 2_000, request: .null,
      result: .object(["response": .string("已经完成")]))
    XCTAssertEqual(store.conversationRailItems(for: [finished])[0].preview, "已经完成")
    XCTAssertEqual(store.conversationRailItems(for: [finished])[0].previewState, .ready)
  }

  @MainActor func testRailShowsRecordedDiffFilesWithoutInventingInputOutputs() throws {
    let diffID = UUID()
    var execution = MCPToolExecution(callID: "tool", serverID: UUID(),
      serverName: "Site", toolName: "create", arguments: "{}")
    execution.status = .succeeded
    execution.mcpResourceActivities = [.init(id: "page",
      source: CodexWebSource(title: "预览页面", url: "https://example.com/page"),
      mimeType: "text/html", activities: [.created])]
    let tool = try JSONDecoder().decode(JSONValue.self,
      from: JSONEncoder().encode([execution]))
    let diff = CodexTurnDiff(id: diffID,
      unifiedDiff: "diff --git a/First.swift b/First.swift\n--- a/First.swift\n+++ b/First.swift\n"
        + "diff --git a/Second.swift b/Second.swift\n--- a/Second.swift\n+++ b/Second.swift\n",
      truncated: true, changedFileCount: 3)
    let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(diff))
    let run = AgentRun(id: "diff-run", kind: "chat", project: "", status: "succeeded",
      createdAt: 1_000, updatedAt: 1_000, request: .null,
      result: .object(["codex_turn_diff": encoded, "tool_executions": tool,
        "response_items": try ChatResponseItem.json([.tool(execution.id), .diff(diffID),
          .message(id: UUID(), text: "完成")])]))
    let store = WorkspaceStore(dataRoot: FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString))
    store.library.notes[run.id] = "修改文件"
    store.library.runFiles[run.id] = [.init(id: UUID(), name: "input.pdf",
      byteCount: 1, sha256: "sample", isPDF: true)]
    let item = try XCTUnwrap(store.conversationRailItems(for: [run]).first)
    XCTAssertEqual(item.outputs.map(\.label), ["预览页面", "First.swift", "Second.swift"])
    XCTAssertEqual(item.additionalOutputCount, 1)
  }

  @MainActor func testRailAssignsCreatedResourceToSteeredTurnOnly() throws {
    let message = QueuedMessage(taskID: "task", text: "创建页面")
    let steer = try JSONDecoder().decode(JSONValue.self,
      from: JSONEncoder().encode([message]))
    var execution = MCPToolExecution(callID: "call", serverID: UUID(),
      serverName: "Site", toolName: "create", arguments: "{}")
    execution.status = .succeeded
    execution.mcpResourceActivities = [.init(id: "page",
      source: CodexWebSource(title: "预览页面", url: "https://example.com/page"),
      mimeType: "text/html", activities: [.created])]
    let tool = try JSONDecoder().decode(JSONValue.self,
      from: JSONEncoder().encode([execution]))
    let run = AgentRun(id: "resource-run", kind: "chat", project: "", status: "succeeded",
      createdAt: 1_000, updatedAt: 1_000, request: .null,
      result: .object(["codex_steered_messages": steer, "tool_executions": tool,
        "response_items": try ChatResponseItem.json([
          .message(id: UUID(), text: "首轮"), .user(message.id),
          .tool(execution.id), .message(id: UUID(), text: "已经创建"),
        ])]))
    let store = WorkspaceStore(dataRoot: FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString))
    store.library.notes[run.id] = "开始"
    let items = store.conversationRailItems(for: [run])
    XCTAssertEqual(items.count, 2)
    XCTAssertTrue(items[0].outputs.isEmpty)
    XCTAssertEqual(items[1].outputs.map(\.label), ["预览页面"])
    XCTAssertEqual(items[1].outputs.map(\.kind), [.website])
  }

  @MainActor func testRailRendersWithoutForegroundWindow() throws {
    let items = (0..<4).map { index in
      ConversationRailItem(id: "run-\(index)", title: "模型", preview: "问题 \(index)",
        date: Date(timeIntervalSince1970: 0), bookmarked: index == 0)
    }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 500),
      styleMask: [.borderless], backing: .buffered, defer: false)
    let host = NSHostingView(rootView: ConversationRailOverlay(items: items,
      currentIDs: [items[0].id], onSelect: { _ in }, onBookmark: { _, _ in },
      visualizer: SystemAudioVisualizer(), audioEnabled: false, onAudioError: { _ in }))
    window.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: 320, height: 500)
    host.layoutSubtreeIfNeeded()
    let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: image)
    XCTAssertGreaterThan(image.pixelsWide, 0)
  }
}
