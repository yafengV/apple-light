import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class ConversationReadingNavigationTests: XCTestCase {
  private enum Surface { case main, task }

  func testMainChatRoundTripPreservesIndependentReadingPositionsAndDoesNotFollowBackgroundReply() async throws {
    try await verify(.main)
  }
  func testTaskWindowChatRoundTripPreservesIndependentReadingPositionsAndDoesNotFollowBackgroundReply() async throws {
    try await verify(.task)
  }
  func testMainChatRoundTripKeepsFollowingBackgroundReplyForBottomReader() async throws {
    try await verify(.main, readingHistory: false)
  }
  func testTaskWindowChatRoundTripKeepsFollowingBackgroundReplyForBottomReader() async throws {
    try await verify(.task, readingHistory: false)
  }
  func testMainReturnWithoutNewReplyDoesNotInventNewContentIndicator() async throws {
    try await verify(.main, backgroundReply: false)
  }
  func testTaskWindowReturnWithoutNewReplyDoesNotInventNewContentIndicator() async throws {
    try await verify(.task, backgroundReply: false)
  }

  private func verify(_ surface: Surface, readingHistory: Bool = true, backgroundReply: Bool = true) async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("reading-navigation-\(UUID())")
    let store = WorkspaceStore(dataRoot: root, agentExecutable: root.appendingPathComponent("absent-agent"))
    store.libraryLoaded = true; store.scopeLoaded = true
    let runs = (0..<2).flatMap { task in
      (0..<8).map { turn in
        AgentRun(id: "\(task)-\(turn)", kind: "chat", project: "", status: "succeeded",
          createdAt: Double(turn + 1), updatedAt: Double(turn + 1),
          request: .object(["model": .string("Test Model")]),
          result: .object(["response": .string(String(repeating: "Task \(task), turn \(turn). ", count: 40))]))
      }
    }
    let tasks = (0..<2).map { task in
      WorkspaceTask(id: "task-\(task)", project: "", title: "Chat \(task)",
        runIDs: (0..<8).map { "\(task)-\($0)" })
    }
    store.library.tasks = tasks; store.library.chatRuns = runs
    store.selectTask(tasks[0])
    let resources = TaskWindowResources()
    tasks.forEach { resources.prepare($0.id, store: store) }
    let size = NSSize(width: 900, height: 740)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    func view(_ index: Int) -> AnyView {
      switch surface {
      case .main: return AnyView(ConversationView(store: store))
      case .task:
        return AnyView(TaskWindowView(store: store, taskID: tasks[index].id,
          tabs: resources.tasks[tasks[index].id]!, resources: resources,
          renameHistory: TaskRenameHistory(), onNavigate: { _ in }, canGoBack: false,
          canGoForward: false, onMove: { _ in }).id(tasks[index].id))
      }
    }
    let host = NSHostingView(rootView: view(0))
    resources.display(tasks[0].id)
    window.contentView = host; host.frame.size = size
    addTeardownBlock {
      await MainActor.run { window.close(); resources.shutdown() }
      await store.shutdown()
      try? FileManager.default.removeItem(at: root)
    }
    func timeline() throws -> NSScrollView {
      try XCTUnwrap(scrollViews(host).max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) })
    }
    func settle() async throws {
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(450))
      host.layoutSubtreeIfNeeded()
    }
    func show(_ index: Int) async throws {
      switch surface {
      case .main: store.selectTask(tasks[index])
      case .task:
        resources.display(tasks[index].id)
        host.rootView = view(index)
      }
      try await settle()
    }
    func move(_ offset: CGFloat) async throws -> CGFloat {
      let scroll = try timeline(), height = try XCTUnwrap(scroll.documentView).bounds.height
      XCTAssertGreaterThan(height, scroll.contentView.bounds.height + offset + 100)
      let y = scroll.documentView?.isFlipped == true ? offset : height - scroll.contentView.bounds.height - offset
      scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
      scroll.reflectScrolledClipView(scroll.contentView)
      try await settle()
      return position(scroll)
    }
    try await settle()
    func verifyBottom() throws {
      let scroll = try timeline()
      XCTAssertLessThanOrEqual((scroll.documentView?.bounds.height ?? 0)
        - scroll.contentView.bounds.height - position(scroll), 40)
    }
    let first = readingHistory ? try await move(120) : position(try timeline())
    if !readingHistory { try verifyBottom() }
    try await show(1)
    let second = readingHistory ? try await move(280) : position(try timeline())
    if !readingHistory { try verifyBottom() }
    // The first chat receives a reply while another chat is visible.
    if backgroundReply {
      store.library.chatRuns[7] = AgentRun(id: runs[7].id, kind: "chat", project: "",
        status: "succeeded", createdAt: runs[7].createdAt, updatedAt: 100,
        request: runs[7].request,
        result: .object(["response": .string(String(repeating: "New background reply. ", count: 90))]))
    }
    try await show(0)
    if readingHistory {
      XCTAssertEqual(position(try timeline()), first, accuracy: 10,
        "Returning to history must preserve this chat's position despite a background reply")
    } else { try verifyBottom() }
    try await show(1)
    if readingHistory {
      let cache = surface == .main ? store.conversationReadingPositions : resources.conversationReadingPositions
      XCTAssertEqual(cache.position(for: tasks[0].id)?.hasNewContent, backgroundReply,
        "Recreating a timeline must not be treated as a new reply")
    }
    if readingHistory {
      XCTAssertEqual(position(try timeline()), second, accuracy: 10,
        "The other chat must keep its own reading position")
    } else { try verifyBottom() }
    switch surface {
    case .main:
      XCTAssertNotNil(store.conversationReadingPositions.position(for: tasks[0].id))
      XCTAssertNil(resources.conversationReadingPositions.position(for: tasks[0].id))
      if readingHistory {
        store.selectTask(tasks[0])
        store.conversationReveal = .init(runID: "0-7")
        try await settle()
        XCTAssertGreaterThan(position(try timeline()), first + 100,
          "An explicit notification reveal must take priority over the remembered position")
        let afterReveal = try await move(180)
        try await show(1); try await show(0)
        XCTAssertEqual(position(try timeline()), afterReveal, accuracy: 10,
          "Returning later must not replay an already handled notification reveal")
        try await show(1)
      }
    case .task:
      XCTAssertNotNil(resources.conversationReadingPositions.position(for: tasks[0].id))
      XCTAssertNil(store.conversationReadingPositions.position(for: tasks[0].id))
    }
    switch surface {
    case .main: XCTAssertEqual(store.selectedTask?.id, tasks[1].id)
    case .task: XCTAssertEqual(store.selectedTask?.id, tasks[0].id, "Task-window navigation must not change the main chat")
    }
    XCTAssertFalse(window.isVisible)
  }

  private func position(_ scroll: NSScrollView) -> CGFloat {
    scroll.documentView?.isFlipped == true ? scroll.contentView.bounds.minY
      : (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.maxY
  }
  private func scrollViews(_ view: NSView) -> [NSScrollView] {
    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
  }
}
