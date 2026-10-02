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
    XCTAssertEqual(ConversationRailSelection.current(
      positions: ["first": -250, "second": 90, "third": 420],
      orderedIDs: ["first", "second", "third"]), "second")
    XCTAssertEqual(ConversationRailSelection.scrubbedID(y: -20,
      orderedIDs: ["first", "second"]), "first")
    XCTAssertEqual(ConversationRailSelection.scrubbedID(y: 100,
      orderedIDs: ["first", "second"]), "second")
    XCTAssertNil(ConversationRailSelection.scrubbedID(y: 0, orderedIDs: []))
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
        "response_items": try ChatResponseItem.json([.user(message.id)]),
      ]))
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.library.chatRuns = [run]
    store.library.notes[run.id] = "首条问题"
    store.library.tasks = [WorkspaceTask(id: "task", project: "", title: "会话", runIDs: [run.id])]
    let items = store.conversationRailItems(for: [run])
    let steeredID = ConversationRailItem.steeredID(runID: run.id, messageID: message.id)
    XCTAssertEqual(items.map(\.id), [run.id, steeredID])
    XCTAssertEqual(items.map(\.preview), ["首条问题", "后续问题"])
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

  @MainActor func testRailRendersWithoutForegroundWindow() throws {
    let items = (0..<4).map { index in
      ConversationRailItem(id: "run-\(index)", title: "模型", preview: "问题 \(index)",
        date: Date(timeIntervalSince1970: 0), bookmarked: index == 0)
    }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 500),
      styleMask: [.borderless], backing: .buffered, defer: false)
    let host = NSHostingView(rootView: ConversationRailOverlay(items: items,
      currentID: items[0].id, onSelect: { _ in }, onBookmark: { _, _ in },
      visualizer: SystemAudioVisualizer(), audioEnabled: false, onAudioError: { _ in }))
    window.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: 320, height: 500)
    host.layoutSubtreeIfNeeded()
    let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: image)
    XCTAssertGreaterThan(image.pixelsWide, 0)
  }
}
