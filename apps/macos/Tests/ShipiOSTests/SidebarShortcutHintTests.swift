import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class SidebarShortcutHintTests: XCTestCase {
  private func makeStore() async -> WorkspaceStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-hints-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.library.tasks = (1...11).map {
      .init(id: "task\($0)", project: "", title: "Task \($0)", runIDs: ["run\($0)"])
    }
    return store
  }

  private func settled() async throws { try await Task.sleep(for: .milliseconds(600)) }

  func testHintsUseActualBindingsAndDoNotShiftDisabledSlots() async throws {
    let store = await makeStore()
    XCTAssertEqual(store.sidebarShortcutHintContext.modifier, .control)
    XCTAssertEqual(store.sidebarShortcutHintContext.labels.count, 9)
    XCTAssertEqual(store.sidebarShortcutHintContext.labels["task9"], "⌃9")
    XCTAssertNil(store.sidebarShortcutHintContext.labels["task10"])
    try store.shortcuts.set(nil, for: "focus-chat-2")
    try store.shortcuts.set(ShortcutBinding("⌘⇧8"), for: "focus-chat-1")
    XCTAssertEqual(store.sidebarShortcutHintContext.labels["task1"], "⇧⌘8")
    XCTAssertNil(store.sidebarShortcutHintContext.labels["task2"])
    XCTAssertEqual(store.sidebarShortcutHintContext.labels["task3"], "⌃3")
    try store.shortcuts.setNumberShortcutTarget(.sidebar)
    XCTAssertEqual(store.sidebarShortcutHintContext.modifier, .command)
    XCTAssertEqual(store.sidebarShortcutHintContext.labels["task1"], "⇧⌘8")
    XCTAssertEqual(store.sidebarShortcutHintContext.labels["task3"], "⌘3")
    XCTAssertThrowsError(try store.shortcuts.set(ShortcutBinding("⌘3"), for: "search"))
    XCTAssertEqual(store.sidebarShortcutHintContext.labels["task3"], "⌘3", "A rejected rebind must preserve the effective hint")
    await store.shutdown()
  }

  func testHintsFollowVisibleSectionsWithoutAliasingOrCollapsedChildren() async {
    let store = await makeStore()
    store.library.projects = ["/a"]
    store.library.tasks[0].project = "/a"
    store.library.moveSidebarItem(.task("task11"), to: SidebarLayout.pinned)
    store.library.collapsedProjects.insert("/a")
    let ids = store.library.visibleSidebarTasks.prefix(9).map(\.id)
    XCTAssertEqual(ids.first, "task11")
    XCTAssertNil(store.sidebarShortcutHintContext.labels["task1"])
    for (index, id) in ids.enumerated() {
      XCTAssertEqual(store.sidebarShortcutHintContext.labels[id], "⌃\(index + 1)")
    }
    store.library.tasks[10].archived = true
    XCTAssertNil(store.sidebarShortcutHintContext.labels["task11"])
    XCTAssertEqual(store.sidebarShortcutHintContext.labels[ids[1]], "⌃1")
    await store.shutdown()
  }

  func testActivityHasNoLocalRowHintsAndClosingRestoresOrdinaryContext() async {
    let store = await makeStore()
    let ordinary = store.sidebarShortcutHintContext
    store.toggleActivity()
    XCTAssertTrue(store.sidebarShortcutHintContext.labels.isEmpty)
    store.setActivityOption(\.showPriority, to: false)
    XCTAssertTrue(store.sidebarShortcutHintContext.labels.isEmpty)
    store.closeActivity()
    XCTAssertEqual(store.sidebarShortcutHintContext, ordinary)
    await store.shutdown()
  }

  func testSettingsOverlaysRecordingAndConfirmationSuppressHints() async {
    let store = await makeStore()
    store.openSettings(.shortcuts)
    XCTAssertTrue(store.sidebarShortcutHintContext.labels.isEmpty)
    store.closeSettings()
    store.showingCommands = true
    XCTAssertTrue(store.sidebarShortcutHintContext.labels.isEmpty)
    store.showingCommands = false
    store.shortcutCaptureCount = 1
    XCTAssertTrue(store.sidebarShortcutHintContext.labels.isEmpty)
    store.shortcutCaptureCount = 0
    store.shortcutResetRequested = true
    XCTAssertTrue(store.sidebarShortcutHintContext.labels.isEmpty)
    store.shortcutResetRequested = false
    store.renameTaskID = "task1"
    XCTAssertTrue(store.sidebarShortcutHintContext.labels.isEmpty)
    store.renameTaskID = nil
    store.renameProjectPath = "/a"
    XCTAssertTrue(store.sidebarShortcutHintContext.labels.isEmpty)
    store.renameProjectPath = nil
    XCTAssertEqual(store.sidebarShortcutHintContext.labels.count, 9)
    store.libraryLoaded = false
    XCTAssertTrue(store.sidebarShortcutHintContext.labels.isEmpty)
    store.libraryLoaded = true
    await store.shutdown()
  }

  func testHoldShowsHintsAfterDelayAndReleaseHidesImmediately() async throws {
    let controller = SidebarShortcutHintController()
    let context = SidebarShortcutHintContext(modifier: .control, labels: ["task": "⌃1"])
    controller.update(context, held: true, eligible: true)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(controller.labels.isEmpty, "Brief modifier presses must not flash labels")
    try await settled()
    XCTAssertEqual(controller.labels, context.labels)
    controller.update(context, held: false, eligible: true)
    XCTAssertTrue(controller.labels.isEmpty)
  }

  func testReleaseBeforeDeadlineCancelsPendingPresentation() async throws {
    let controller = SidebarShortcutHintController()
    let context = SidebarShortcutHintContext(modifier: .command, labels: ["task": "⌘1"])
    controller.update(context, held: true, eligible: true)
    controller.update(context, held: false, eligible: true)
    try await settled()
    XCTAssertTrue(controller.labels.isEmpty)
  }

  func testChangingTargetsCancelsOldRequestAndDelaysNewLabels() async throws {
    let controller = SidebarShortcutHintController()
    let old = SidebarShortcutHintContext(modifier: .control, labels: ["old": "⌃1"])
    let new = SidebarShortcutHintContext(modifier: .command, labels: ["new": "⌘1"])
    controller.update(old, held: true, eligible: true)
    try await settled()
    XCTAssertEqual(controller.labels, old.labels)
    controller.update(new, held: true, eligible: true)
    XCTAssertTrue(controller.labels.isEmpty)
    try await settled()
    XCTAssertEqual(controller.labels, new.labels)
    controller.update(new, held: false, eligible: true)
    XCTAssertTrue(controller.labels.isEmpty)
  }

  func testWindowLossModalOrDismantleCannotRevealPendingHints() async throws {
    let controller = SidebarShortcutHintController()
    let context = SidebarShortcutHintContext(modifier: .command, labels: ["task": "⌘1"])
    controller.update(context, held: true, eligible: true)
    controller.update(context, held: true, eligible: false)
    try await settled()
    XCTAssertTrue(controller.labels.isEmpty)
    controller.update(context, held: true, eligible: true)
    controller.reset()
    try await settled()
    XCTAssertTrue(controller.labels.isEmpty)
    controller.update(context, held: true, eligible: false)
    try await settled()
    XCTAssertTrue(controller.labels.isEmpty)
  }

  func testEmptyContextCancelsShownHintsAndRepeatedUpdatesDoNotRestartDelay() async throws {
    let controller = SidebarShortcutHintController()
    let context = SidebarShortcutHintContext(modifier: .control, labels: ["task": "⌃1"])
    controller.update(context, held: true, eligible: true)
    for _ in 0..<6 {
      try await Task.sleep(for: .milliseconds(100))
      controller.update(context, held: true, eligible: true)
    }
    XCTAssertEqual(controller.labels, context.labels)
    controller.update(.init(modifier: .control, labels: [:]), held: true, eligible: true)
    XCTAssertTrue(controller.labels.isEmpty)
    try await settled()
    XCTAssertTrue(controller.labels.isEmpty)
  }

  func testNativeMonitorDoesNotRetainViewAndDismantleCancelsPresentation() async throws {
    let controller = SidebarShortcutHintController()
    let coordinator = SidebarShortcutHintBridge.Coordinator(controller: controller)
    var view: NSView? = NSView()
    weak var releasedView = view
    coordinator.install(try XCTUnwrap(view))
    view = nil
    XCTAssertNil(releasedView, "A modifier monitor must not keep a discarded sidebar attached")
    let context = SidebarShortcutHintContext(modifier: .command, labels: ["task": "⌘1"])
    controller.update(context, held: true, eligible: true)
    coordinator.stop()
    coordinator.stop()
    try await settled()
    XCTAssertTrue(controller.labels.isEmpty)
    controller.update(context, held: true, eligible: true)
    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    try await settled()
    XCTAssertEqual(controller.labels, context.labels, "Disposed observers cannot affect a reused controller")
    controller.reset()
  }
}
