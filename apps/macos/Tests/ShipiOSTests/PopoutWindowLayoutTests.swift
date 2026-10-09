import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

final class PopoutWindowLayoutTests: XCTestCase {
  @MainActor func testOpenThreadInMainSelectsItsTaskAndPreservesDraft() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    let other = try XCTUnwrap(store.createPopoutTask(projectless: true))
    store.library.tasks[store.library.tasks.firstIndex(where: { $0.id == other.id })!].popoutDraft = nil
    store.selectTask(other)
    let target = try XCTUnwrap(store.createPopoutTask(projectless: true))
    store.setTaskWindowDraft("Keep this unsent reply", taskID: target.id)
    store.popoutHomeDraft = "Keep the new chat draft"
    var openedMain = 0
    store.showMainWindowHandler = { openedMain += 1 }
    let controller = PopoutWindowController(store: store)
    defer { controller.hide() }
    controller.openThread(target.id)
    XCTAssertTrue(controller.hasVisibleWindow)
    controller.openThreadInMainWindow(target.id)
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(openedMain, 0, "An unsent popout draft cannot become a main-window task")
    XCTAssertEqual(store.selectedTask?.id, other.id)
    XCTAssertTrue(controller.hasVisibleWindow)

    store.library.tasks[store.library.tasks.firstIndex(where: { $0.id == target.id })!].popoutDraft = nil
    store.busy = true
    controller.openThreadInMainWindow(target.id)
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(openedMain, 0)
    XCTAssertEqual(store.selectedTask?.id, other.id)
    XCTAssertTrue(controller.hasVisibleWindow)
    XCTAssertEqual(store.error, "无法在主窗口打开此任务，请稍后重试。")
    store.busy = false
    store.error = nil
    controller.openThreadInMainWindow(target.id)
    for _ in 0..<20 where openedMain == 0 {
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertEqual(openedMain, 1)
    XCTAssertEqual(store.selectedTask?.id, target.id)
    XCTAssertEqual(store.taskWindowDraft(target.id), "Keep this unsent reply")
    XCTAssertEqual(store.popoutHomeDraft, "Keep the new chat draft")
    XCTAssertFalse(controller.hasVisibleWindow)
  }

  @MainActor func testHomeAndThreadSurfacesRenderAtReferenceInitialSizes() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    let controller = PopoutWindowController(store: store)
    XCTAssertNil(controller.state.visibleSurface)
    XCTAssertFalse(controller.hasVisibleWindow, "Startup must not display the popout")
    let panel = try XCTUnwrap(NSApp.windows.first { $0.delegate === controller })
    XCTAssertEqual(panel.styleMask, .borderless)
    XCTAssertTrue(panel.canBecomeKey)
    XCTAssertTrue(panel.isMovableByWindowBackground)
    let task = try XCTUnwrap(store.createPopoutTask())

    let cases: [(String, NSSize, AnyView)] = [
      ("home", NSSize(width: 470, height: 290), AnyView(PopoutHomeView(store: store,
        onSubmit: { _, _, _ in false }, onOpenThread: { _ in }, onHide: {}))),
      ("thread", NSSize(width: 470, height: 640), AnyView(PopoutThreadView(store: store,
        taskID: task.id, onHome: {}, onOpenThread: { _ in },
        onOpenInMain: { _ in }, onHide: {})))
    ]
    for (name, size, view) in cases {
      let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      let host = NSHostingView(rootView: view)
      window.contentView = host
      host.frame = NSRect(origin: .zero, size: size)
      try await Task.sleep(for: .milliseconds(180))
      host.layoutSubtreeIfNeeded()
      XCTAssertFalse(window.isVisible)
      XCTAssertGreaterThan(textViews(in: host).count, 0, name)
      let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: image)
      let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
      XCTAssertGreaterThan(data.count, 5_000, name)
      if let path = ProcessInfo.processInfo.environment["SHIPIOS_POPOUT_SNAPSHOTS"] {
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("popout-\(name).png"))
      }
      window.close()
    }
  }

  @MainActor func testHomeWithAttachmentRendersAtFixedReferenceSize() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.popoutHomeDraft = "Describe this file"
    store.library.draftFiles[WorkspaceStore.popoutHomeDraftKey] = [
      FileAttachment(id: UUID(), name: "notes.txt", byteCount: 12,
        sha256: "fixture", isPDF: false)
    ]
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 290),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: PopoutHomeView(store: store,
      onSubmit: { _, _, _ in false }, onOpenThread: { _ in }, onHide: {}))
    window.contentView = host
    host.frame.size = NSSize(width: 470, height: 290)
    try await Task.sleep(for: .milliseconds(180))
    host.layoutSubtreeIfNeeded()
    XCTAssertFalse(window.isVisible)
    let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: image)
    let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
    XCTAssertGreaterThan(data.count, 5_000)
    if let path = ProcessInfo.processInfo.environment["SHIPIOS_POPOUT_SNAPSHOTS"] {
      let folder = URL(fileURLWithPath: path)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try data.write(to: folder.appendingPathComponent("popout-home-attachment.png"))
    }
  }

  @MainActor func testHomeShowsSelectedProjectAtFixedReferenceSize() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.library.projects = [project.path]
    store.project = project
    let size = NSSize(width: 470, height: 290)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: PopoutHomeView(store: store,
      onSubmit: { _, _, _ in false }, onOpenThread: { _ in }, onHide: {}))
    window.contentView = host
    host.frame.size = size
    try await Task.sleep(for: .milliseconds(180))
    host.layoutSubtreeIfNeeded()
    XCTAssertFalse(window.isVisible)
    let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: image)
    let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
    XCTAssertGreaterThan(data.count, 5_000)
    if let path = ProcessInfo.processInfo.environment["SHIPIOS_POPOUT_SNAPSHOTS"] {
      let folder = URL(fileURLWithPath: path)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try data.write(to: folder.appendingPathComponent("popout-home-selected-project.png"))
    }
  }

  @MainActor func testSlashMenusFitHomeAndThreadSurfaces() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    store.popoutHomeDraft = "/"
    let task = try XCTUnwrap(store.createPopoutTask())
    store.setTaskWindowDraft("/", taskID: task.id)
    let cases: [(String, NSSize, AnyView)] = [
      ("home-slash", NSSize(width: 470, height: 290), AnyView(PopoutHomeView(store: store,
        onSubmit: { _, _, _ in false }, onOpenThread: { _ in }, onHide: {}))),
      ("thread-slash", NSSize(width: 470, height: 640), AnyView(PopoutThreadView(store: store,
        taskID: task.id, onHome: {}, onOpenThread: { _ in },
        onOpenInMain: { _ in }, onHide: {})))
    ]
    for (name, size, view) in cases {
      let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      let host = NSHostingView(rootView: view)
      window.contentView = host
      host.frame.size = size
      try await Task.sleep(for: .milliseconds(200))
      host.layoutSubtreeIfNeeded()
      let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: image)
      let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
      XCTAssertGreaterThan(data.count, 5_000, name)
      if let path = ProcessInfo.processInfo.environment["SHIPIOS_POPOUT_SNAPSHOTS"] {
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("popout-\(name).png"))
      }
      XCTAssertFalse(window.isVisible)
      window.close()
    }
  }

  @MainActor func testRunningThreadAndItsQueueRenderAtFixedSize() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    let task = try XCTUnwrap(store.createPopoutTask())
    let run = AgentRun(id: "running-popout", kind: "chat", project: task.project,
      status: "running", createdAt: 1, updatedAt: 1,
      request: .object(["model": .string("Test Model")]), result: nil)
    store.library.tasks[store.library.tasks.firstIndex(where: { $0.id == task.id })!].runIDs = [run.id]
    store.runs = [run]
    store.library.queuedMessages = [
      QueuedMessage(taskID: task.id, text: "Next popout question"),
      QueuedMessage(taskID: "other", text: "Unrelated main-window question"),
    ]
    store.setTaskWindowDraft("Follow-up", taskID: task.id)
    XCTAssertTrue(store.taskWindowOwnsActiveRun(task.id))
    XCTAssertEqual(store.library.queuedMessages.filter { $0.taskID == task.id }.count, 1)

    let size = NSSize(width: 470, height: 640)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: PopoutThreadView(store: store, taskID: task.id,
      onHome: {}, onOpenThread: { _ in }, onOpenInMain: { _ in }, onHide: {}))
    window.contentView = host
    host.frame.size = size
    try await Task.sleep(for: .milliseconds(200))
    host.layoutSubtreeIfNeeded()
    XCTAssertFalse(window.isVisible)
    let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: image)
    let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
    XCTAssertGreaterThan(data.count, 5_000)
    if let path = ProcessInfo.processInfo.environment["SHIPIOS_POPOUT_SNAPSHOTS"] {
      let folder = URL(fileURLWithPath: path)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try data.write(to: folder.appendingPathComponent("popout-thread-running-queue.png"))
    }
  }

  @MainActor func testThreadAttachmentsRenderAndRemainScopedToItsDraft() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    let task = try XCTUnwrap(store.createPopoutTask())
    let other = try XCTUnwrap(store.createPopoutTask())
    let image = try ImageAttachmentStorage.importData(AttachmentFixture.png(),
      name: "popout.png", root: root)
    let fileURL = root.appendingPathComponent("popout.txt")
    try Data("Popout attachment".utf8).write(to: fileURL)
    let file = try FileAttachmentStorage.importFile(fileURL, root: root)
    store.library.draftImages[task.id] = [image]
    store.library.draftFiles[task.id] = [file]
    store.library.draftImages[other.id] = [image]
    store.library.draftFiles[other.id] = [file]
    store.setTaskWindowDraft("Inspect both attachments", taskID: task.id)

    let size = NSSize(width: 470, height: 640)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: PopoutThreadView(store: store, taskID: task.id,
      onHome: {}, onOpenThread: { _ in }, onOpenInMain: { _ in }, onHide: {}))
    window.contentView = host
    host.frame.size = size
    try await Task.sleep(for: .milliseconds(250))
    host.layoutSubtreeIfNeeded()
    XCTAssertFalse(window.isVisible)
    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    XCTAssertGreaterThan(data.count, 5_000)
    if let path = ProcessInfo.processInfo.environment["SHIPIOS_POPOUT_SNAPSHOTS"] {
      let folder = URL(fileURLWithPath: path)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try data.write(to: folder.appendingPathComponent("popout-thread-attachments.png"))
    }

    store.removeDraftImage(image, draft: task.id)
    store.removeDraftFile(file, draft: task.id)
    XCTAssertTrue(store.taskWindowImages(task.id).isEmpty)
    XCTAssertTrue(store.taskWindowFiles(task.id).isEmpty)
    XCTAssertEqual(store.taskWindowImages(other.id), [image])
    XCTAssertEqual(store.taskWindowFiles(other.id), [file])
    XCTAssertEqual(store.taskWindowDraft(task.id), "Inspect both attachments")
  }

  @MainActor func testThreadPlanActionsRenderWithoutSelectingItInMainWindow() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    let task = try XCTUnwrap(store.createPopoutTask())
    let plan = AgentRun(id: "popout-plan", kind: "chat", project: task.project,
      status: "succeeded", createdAt: 1, updatedAt: 2,
      request: .object(["mode": .string(ChatMode.plan.rawValue),
        "model": .string("Test Model")]),
      result: .object(["response": .string("Build, test, and review the app.")]))
    store.library.tasks[store.library.tasks.firstIndex(where: { $0.id == task.id })!].runIDs = [plan.id]
    store.library.chatRuns = [plan]
    XCTAssertNotEqual(store.selectedTask?.id, task.id)

    let size = NSSize(width: 470, height: 640)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: PopoutThreadView(store: store, taskID: task.id,
      onHome: {}, onOpenThread: { _ in }, onOpenInMain: { _ in }, onHide: {}))
    window.contentView = host
    host.frame.size = size
    try await Task.sleep(for: .milliseconds(200))
    host.layoutSubtreeIfNeeded()
    XCTAssertNotEqual(store.selectedTask?.id, task.id)
    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    XCTAssertGreaterThan(data.count, 5_000)
    if let path = ProcessInfo.processInfo.environment["SHIPIOS_POPOUT_SNAPSHOTS"] {
      let folder = URL(fileURLWithPath: path)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try data.write(to: folder.appendingPathComponent("popout-thread-plan-actions.png"))
    }
  }

  @MainActor func testScrolledThreadShowsReturnToLatestWhileReplyChanges() async throws {
    try await verifyHistoryScrollDuringReply(delay: .milliseconds(180))
  }

  @MainActor func testHistoryScrollAndReplyInSameLayoutTurnKeepsReaderDetached() async throws {
    for width in [400.0, 620.0] {
      try await verifyHistoryScrollDuringReply(delay: nil, width: width)
    }
  }

  @MainActor private func verifyHistoryScrollDuringReply(delay: Duration?, width: Double = 470) async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true
    let task = try XCTUnwrap(store.createPopoutTask())
    let original = (0..<8).map { index in
      AgentRun(id: "history-\(index)", kind: "chat", project: task.project,
        status: "succeeded", createdAt: Double(index + 1), updatedAt: Double(index + 1),
        request: .object(["model": .string("Test Model")]),
        result: .object(["response": .string(String(repeating: "Conversation line \(index). ",
          count: 18))]))
    }
    store.library.tasks[store.library.tasks.firstIndex(where: { $0.id == task.id })!].runIDs =
      original.map(\.id)
    store.library.chatRuns = original
    let size = NSSize(width: width, height: 640)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: PopoutThreadView(store: store, taskID: task.id,
      onHome: {}, onOpenThread: { _ in }, onOpenInMain: { _ in }, onHide: {}))
    window.contentView = host
    host.frame.size = size
    try await Task.sleep(for: .milliseconds(350))
    host.layoutSubtreeIfNeeded()
    let conversation = try XCTUnwrap(scrollViews(in: host).max(by: {
      ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0)
    }))
    XCTAssertGreaterThan(conversation.documentView?.bounds.height ?? 0,
      conversation.contentView.bounds.height + 100)
    for _ in 0..<20 {
      let height = conversation.documentView?.bounds.height ?? 0
      let clip = conversation.contentView.bounds
      let offset = conversation.documentView?.isFlipped == true
        ? clip.minY : height - clip.maxY
      if height - clip.height - offset < 80 { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    let height = conversation.documentView?.bounds.height ?? 0
    let clip = conversation.contentView.bounds
    let offset = conversation.documentView?.isFlipped == true
      ? clip.minY : height - clip.maxY
    XCTAssertLessThan(height - clip.height - offset, 80,
      "An existing popout conversation should initially follow the newest reply")
    conversation.contentView.scroll(to: .zero)
    conversation.reflectScrolledClipView(conversation.contentView)
    if let delay { try await Task.sleep(for: delay) }
    let readingPosition = conversation.contentView.bounds.origin.y
    store.library.chatRuns[7] = AgentRun(id: original[7].id, kind: "chat", project: task.project,
      status: "succeeded", createdAt: original[7].createdAt, updatedAt: 100,
      request: original[7].request,
      result: .object(["response": .string(String(repeating: "New streamed text. ", count: 40))]))
    try await Task.sleep(for: .milliseconds(220))
    host.layoutSubtreeIfNeeded()
    XCTAssertLessThan(abs(conversation.contentView.bounds.origin.y - readingPosition), 10,
      "New content must not pull a reader away from earlier messages")
    XCTAssertFalse(window.isVisible)
    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    XCTAssertGreaterThan(data.count, 5_000)
    if let path = ProcessInfo.processInfo.environment["SHIPIOS_POPOUT_SNAPSHOTS"] {
      let folder = URL(fileURLWithPath: path)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try data.write(to: folder.appendingPathComponent("popout-thread-scrolled-new-content.png"))
    }
  }

  @MainActor private func textViews(in view: NSView) -> [NSTextView] {
    (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
  }

  @MainActor private func scrollViews(in view: NSView) -> [NSScrollView] {
    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
  }
}
