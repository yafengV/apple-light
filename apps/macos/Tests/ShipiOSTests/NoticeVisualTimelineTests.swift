import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

final class NoticeVisualTimelineTests: XCTestCase {
  func testActualToastRemovalCallbackAndCSSExitRules() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "notice_lifecycle_reference",
      withExtension: "json", subdirectory: "Fixtures"))
    let reference = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    XCTAssertEqual(reference["initialSHA256"] as? String,
      "01c04b2e5a96e5dd4c97e02ffa183f571a55bef7a221abd99404246c430f2212")
    XCTAssertEqual(reference["componentSHA256"] as? String,
      "6ee362d34edc3538eeab9c0db276847fe30f7d6c7ad868e0e9051235fa7ac8f3")
    let close = try XCTUnwrap(reference["close"] as? [String: Any])
    XCTAssertEqual(close["afterClick"] as? [String],
      ["removed", "heights:0", "timer:200", "dismiss-callback"])
    XCTAssertEqual(close["afterDelay"] as? [String],
      ["removed", "heights:0", "timer:200", "dismiss-callback", "unmount"])
    XCTAssertEqual(close["delayMilliseconds"] as? Int, 200)
    let css = try XCTUnwrap(reference["css"] as? [String: Any])
    XCTAssertTrue((css["toast"] as? String)?.contains("transition:transform .4s,opacity .4s,height .4s") == true)
    XCTAssertTrue((css["frontExit"] as? String)?.contains("-100%") == true)
    XCTAssertTrue((css["backCollapsedExit"] as? String)?.contains("translateY(40%)") == true)
    XCTAssertEqual(css["reducedMotion"] as? Bool, true)
  }

  func testFrontRemovalRetainsExitWhileSurvivorsReflowImmediately() {
    let notices = WorkspaceNotices()
    notices.show(id: "old", title: "Old", level: .info, at: 10)
    notices.show(id: "front", title: "Front", level: .info, at: 10)
    let front = notices.items[0], old = notices.items[1]
    let timeline = NoticeVisualTimeline()
    XCTAssertTrue(timeline.reconcile(notices.items, expanded: false, at: 10))
    XCTAssertEqual(timeline.entering, [front.generation, old.generation])
    timeline.recordHeights([front.generation: 70, old.generation: 42])
    timeline.settleEntry(revision: timeline.revision)
    XCTAssertTrue(timeline.entering.isEmpty)
    notices.dismiss(front.id, generation: front.generation)
    XCTAssertTrue(timeline.reconcile(notices.items, expanded: false, at: 11))
    XCTAssertEqual(timeline.active.map(\.generation), [old.generation])
    let exit = timeline.exiting[0]
    XCTAssertEqual(exit.id, front.generation)
    XCTAssertEqual(exit.offset, 0)
    XCTAssertEqual(exit.frameHeight, 70)
    XCTAssertEqual(exit.exitOffset, -70)
    timeline.beginExit(revision: timeline.revision)
    XCTAssertTrue(timeline.exiting[0].outward)
    timeline.removeFinished(at: 11.199)
    XCTAssertEqual(timeline.exiting.count, 1)
    timeline.removeFinished(at: 11.201)
    XCTAssertTrue(timeline.exiting.isEmpty)
    XCTAssertNil(timeline.heights[front.generation])
    XCTAssertEqual(timeline.heights[old.generation], 42)
  }

  func testCollapsedBackRemovalFallsAndSwipeDoesNotReplayExit() {
    let notices = WorkspaceNotices()
    notices.show(id: "back", title: "Back", level: .info, at: 10)
    notices.show(id: "front", title: "Front", level: .info, at: 10)
    let front = notices.items[0], back = notices.items[1]
    let timeline = NoticeVisualTimeline()
    timeline.reconcile(notices.items, expanded: false, at: 10)
    timeline.settleEntry(revision: timeline.revision)
    timeline.recordHeights([front.generation: 80, back.generation: 50])
    notices.dismiss(back.id, generation: back.generation)
    timeline.reconcile(notices.items, expanded: false, at: 11)
    let exit = timeline.exiting[0]
    XCTAssertEqual(exit.offset, 8)
    XCTAssertEqual(exit.scale, 0.95)
    XCTAssertEqual(exit.frameHeight, 80)
    XCTAssertEqual(exit.exitOffset, 20)
    timeline.removeFinished(at: 11.3)
    timeline.markSwiped(front.generation, expanded: false)
    XCTAssertTrue(timeline.stacking.isEmpty)
    notices.dismiss(front.id, generation: front.generation)
    timeline.reconcile(notices.items, expanded: false, at: 12)
    XCTAssertTrue(timeline.active.isEmpty)
    XCTAssertTrue(timeline.exiting.isEmpty)
  }

  func testSwipeStartsSurvivorReflowBeforeTheStoreRemovesTheCard() {
    let notices = WorkspaceNotices()
    notices.show(id: "back", title: "Back", level: .info, at: 10)
    notices.show(id: "middle", title: "Middle", level: .info, at: 10)
    notices.show(id: "front", title: "Front", level: .info, at: 10)
    let front = notices.items[0], middle = notices.items[1], back = notices.items[2]
    let timeline = NoticeVisualTimeline(initial: notices.items)
    timeline.recordHeights([front.generation: 70, middle.generation: 50, back.generation: 40])
    timeline.markSwiped(front.generation, expanded: true)
    XCTAssertEqual(timeline.active.map(\.generation), [front.generation, middle.generation, back.generation])
    XCTAssertEqual(timeline.stacking.map(\.generation), [middle.generation, back.generation])
    XCTAssertEqual(timeline.swiping[front.generation]?.offset, 0)
    XCTAssertEqual(timeline.swiping[front.generation]?.frameHeight, 70)
    let reflow = NoticeStackLayout(heights: timeline.stacking.map { timeline.heights[$0.generation] ?? 42 },
      expanded: true)
    XCTAssertEqual(reflow.offset(0), 0)
    XCTAssertEqual(reflow.offset(1), 58)
    notices.dismiss(front.id, generation: front.generation)
    timeline.reconcile(notices.items, expanded: true, at: 11)
    XCTAssertNil(timeline.swiping[front.generation])
    XCTAssertTrue(timeline.exiting.isEmpty, "The card already owns its swipe-out animation")
  }

  func testReplacementStagesNewEntryAndStaleSettleCannotStartItEarly() {
    let notices = WorkspaceNotices()
    notices.show(id: "same", title: "First", level: .info, at: 10)
    let first = notices.items[0]
    let timeline = NoticeVisualTimeline()
    timeline.reconcile(notices.items, expanded: true, at: 10)
    let oldRevision = timeline.revision
    notices.show(id: "same", title: "Second", level: .info, at: 11)
    let second = notices.items[0]
    timeline.reconcile(notices.items, expanded: true, at: 11)
    timeline.settleEntry(revision: oldRevision)
    XCTAssertTrue(timeline.entering.contains(second.generation))
    XCTAssertEqual(timeline.exiting.map(\.id), [first.generation])
    XCTAssertEqual(timeline.exiting[0].exitOffset, -42)
    timeline.settleEntry(revision: timeline.revision)
    timeline.beginExit(revision: timeline.revision)
    XCTAssertFalse(timeline.entering.contains(second.generation))
    XCTAssertTrue(timeline.exiting[0].outward)
  }

  @MainActor func testHiddenNativeStackRetainsRemovedCardUntilExitCompletes() async throws {
    _ = NSApplication.shared
    let store = WorkspaceStore(dataRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    store.notices.show(id: "back", title: "Back", level: .info)
    store.notices.show(id: "front", title: "Front", level: .info)
    let front = store.notices.items[0], back = store.notices.items[1]
    let timeline = NoticeVisualTimeline(initial: store.notices.items)
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 816, height: 500),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: WorkspaceNoticesView(store: store, timeline: timeline))
    window.contentView = host
    try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
    store.notices.dismiss(front.id, generation: front.generation)
    try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded()
    XCTAssertEqual(timeline.active.map(\.generation), [back.generation])
    XCTAssertEqual(timeline.exiting.map(\.id), [front.generation])
    XCTAssertTrue(timeline.exiting[0].outward)
    for _ in 0..<10 where !timeline.exiting.isEmpty {
      try await Task.sleep(for: .milliseconds(30)); host.layoutSubtreeIfNeeded()
    }
    XCTAssertTrue(timeline.exiting.isEmpty)
    XCTAssertFalse(window.isVisible)
  }

  @MainActor func testHiddenNativeStackReflowsBeforeSwipedCardIsRemoved() async throws {
    _ = NSApplication.shared
    let store = WorkspaceStore(dataRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    store.notices.show(id: "back", title: "Back", level: .info)
    store.notices.show(id: "front", title: "Front", level: .info)
    let front = store.notices.items[0], back = store.notices.items[1]
    let timeline = NoticeVisualTimeline(initial: store.notices.items)
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 816, height: 500),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: WorkspaceNoticesView(store: store, timeline: timeline))
    window.contentView = host
    try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
    let before = host.fittingSize.height
    timeline.markSwiped(front.generation, expanded: false)
    try await Task.sleep(for: .milliseconds(30)); host.layoutSubtreeIfNeeded()
    XCTAssertEqual(store.notices.items.count, 2, "The swipe has not yet removed the business toast")
    XCTAssertEqual(timeline.stacking.map(\.generation), [back.generation])
    XCTAssertLessThan(host.fittingSize.height, before, "The surviving card must reflow before dismissal")
    store.notices.dismiss(front.id, generation: front.generation)
    try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded()
    XCTAssertEqual(timeline.active.map(\.generation), [back.generation])
    XCTAssertTrue(timeline.exiting.isEmpty)
    XCTAssertFalse(window.isVisible)
  }
}
