import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class ConversationReadingPositionTests: XCTestCase {
  private enum Surface { case main, task }

  func testMainTimelineKeepsHistoryWhenReplyArrivesInSameLayoutTurn() async throws {
    try await verify(.main)
  }

  func testTaskWindowKeepsHistoryWhenReplyArrivesInSameLayoutTurn() async throws {
    try await verify(.task)
  }

  func testMainTimelineContinuesFollowingNewReplyWhenReaderRemainsAtBottom() async throws {
    try await verify(.main, readingHistory: false)
  }

  func testTaskWindowContinuesFollowingNewReplyWhenReaderRemainsAtBottom() async throws {
    try await verify(.task, readingHistory: false)
  }

  private func verify(_ surface: Surface, readingHistory: Bool = true) async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = WorkspaceStore(dataRoot: root, agentExecutable: root.appendingPathComponent("absent-agent"))
    store.libraryLoaded = true
    let original = (0..<8).map { index in
      AgentRun(id: "history-\(index)", kind: "chat", project: "",
        status: "succeeded", createdAt: Double(index + 1), updatedAt: Double(index + 1),
        request: .object(["model": .string("Test Model")]),
        result: .object(["response": .string(String(repeating: "History line \(index). ", count: 35))]))
    }
    let task = WorkspaceTask(id: "reading", project: "", title: "Reading", runIDs: original.map(\.id))
    store.library.tasks = [task]; store.library.chatRuns = original
    store.selectTask(task)
    let resources = TaskWindowResources()
    resources.prepare(task.id, store: store); resources.display(task.id)
    let tabs = try XCTUnwrap(resources.tasks[task.id])
    let view: AnyView
    switch surface {
    case .main: view = AnyView(ConversationTimelineView(store: store))
    case .task:
      view = AnyView(TaskWindowView(store: store, taskID: task.id, tabs: tabs, resources: resources,
        renameHistory: TaskRenameHistory(), onNavigate: { _ in }, canGoBack: false,
        canGoForward: false, onMove: { _ in }))
    }
    let size = NSSize(width: 900, height: 740)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: view)
    window.contentView = host; host.frame.size = size
    addTeardownBlock {
      await MainActor.run { window.close(); resources.shutdown() }
      await store.shutdown()
      try? FileManager.default.removeItem(at: root)
    }
    try await Task.sleep(for: .milliseconds(350))
    host.layoutSubtreeIfNeeded()
    let scroll = try XCTUnwrap(scrollViews(in: host).max(by: {
      ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0)
    }))
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height - offset(scroll) > 40 {
      guard ContinuousClock.now < deadline else {
        XCTFail("Initial conversation must follow the latest reply"); return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    let height = try XCTUnwrap(scroll.documentView).bounds.height
    XCTAssertGreaterThan(height, scroll.contentView.bounds.height + 100)
    if readingHistory {
      let top = scroll.documentView?.isFlipped == true ? 0 : height - scroll.contentView.bounds.height
      scroll.contentView.scroll(to: NSPoint(x: 0, y: top))
      scroll.reflectScrolledClipView(scroll.contentView)
    }
    let position = offset(scroll)
    store.library.chatRuns[7] = AgentRun(id: original[7].id, kind: "chat", project: "",
      status: "succeeded", createdAt: original[7].createdAt, updatedAt: 100,
      request: original[7].request,
      result: .object(["response": .string(String(repeating: "A new streamed reply. ", count: 60))]))
    try await Task.sleep(for: .milliseconds(250))
    host.layoutSubtreeIfNeeded()
    if readingHistory {
      XCTAssertLessThan(abs(offset(scroll) - position), 10,
        "A reply arriving in the same run loop must preserve the reader's history position")
    } else {
      XCTAssertLessThanOrEqual((scroll.documentView?.bounds.height ?? 0)
        - scroll.contentView.bounds.height - offset(scroll), 40,
        "A reader at the bottom must continue following the new reply")
    }
    XCTAssertFalse(window.isVisible)
  }

  private func offset(_ scroll: NSScrollView) -> CGFloat {
    let bounds = scroll.contentView.bounds
    return scroll.documentView?.isFlipped == true ? bounds.minY
      : (scroll.documentView?.bounds.height ?? 0) - bounds.maxY
  }

  private func scrollViews(in view: NSView) -> [NSScrollView] {
    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
  }
}
