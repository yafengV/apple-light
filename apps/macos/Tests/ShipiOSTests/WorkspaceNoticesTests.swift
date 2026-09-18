import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

final class WorkspaceNoticesTests: XCTestCase {
  func testLifetimePausePendingReplacementAndStack() {
    let notices = WorkspaceNotices()
    notices.show(id: "restore", title: "Restoring", level: .pending)
    notices.advance(by: 100)
    notices.dismiss("restore")
    XCTAssertEqual(notices.items.count, 1)
    notices.show(id: "restore", title: "Restored", level: .info, taskID: "task")
    notices.advance(by: 4)
    notices.paused = true
    notices.advance(by: 100)
    XCTAssertEqual(notices.items.first?.remaining, 1)
    notices.paused = false
    notices.advance(by: 1)
    XCTAssertTrue(notices.items.isEmpty)
    for index in 0..<5 { notices.show(id: "\(index)", title: "Restored", level: .info) }
    XCTAssertEqual(notices.visible.map(\.id), ["4", "3", "2"])
    notices.dismiss("4")
    XCTAssertEqual(notices.visible.map(\.id), ["3", "2", "1"])
    notices.show(id: "3", title: "Retry", level: .error)
    XCTAssertEqual(notices.items.count, 4)
    XCTAssertEqual(notices.items.first?.title, "Retry")
    notices.advance(by: .nan)
    XCTAssertEqual(notices.items.first?.remaining, 5)
  }

  @MainActor func testRestoreViewUsesLatestTaskWithoutLosingDraft() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    store.library.tasks = [.init(id: "one", project: "", title: "Old", runIDs: [], archived: true)]
    store.library.drafts["one"] = "keep"
    store.openSettings(.archived)
    await store.restoreArchivedTaskWithFeedback("one")
    XCTAssertEqual(store.destination, .settings)
    XCTAssertFalse(store.library.tasks[0].archived)
    XCTAssertTrue(store.restoringArchivedTaskIDs.isEmpty)
    let notice = try XCTUnwrap(store.notices.items.first)
    XCTAssertEqual(notice.taskID, "one")
    store.library.tasks[0].title = "Renamed"
    await store.openNoticeTask(notice)
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertEqual(store.selectedTask?.title, "Renamed")
    XCTAssertEqual(store.library.drafts["one"], "keep")
    XCTAssertTrue(store.notices.items.isEmpty)
  }

  @MainActor func testRestoreFailureAndStaleViewDoNotClaimSuccess() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("workspace.json"), withIntermediateDirectories: true)
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    store.library.tasks = [.init(id: "one", project: "", title: "One", runIDs: [], archived: true)]
    store.openSettings(.archived)
    await store.restoreArchivedTaskWithFeedback("one")
    XCTAssertTrue(store.library.tasks[0].archived)
    XCTAssertEqual(store.notices.items.first?.level, .error)
    XCTAssertNil(store.notices.items.first?.taskID)
    XCTAssertTrue(store.restoringArchivedTaskIDs.isEmpty)
    store.notices.show(id: "restore-one", title: "Restored", level: .info, taskID: "one")
    let notice = try XCTUnwrap(store.notices.items.first)
    store.library.tasks = []
    await store.openNoticeTask(notice)
    XCTAssertEqual(store.destination, .settings)
    XCTAssertEqual(store.notices.items.first?.level, .error)
    XCTAssertNil(store.notices.items.first?.taskID)
  }

  @MainActor func testRestorationToastDoesNotReflowOrOpenAnotherWindow() async throws {
    _ = NSApplication.shared
    let store = WorkspaceStore(dataRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    store.destination = .settings
    store.library.tasks = [.init(id: "one", project: "", title: "Archived task", runIDs: [], archived: true)]
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 816, height: 500),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: ArchivedTasksSettingsView(store: store)
      .overlay(alignment: .top) { WorkspaceNoticesView(store: store) })
    window.contentView = host
    host.frame.size = NSSize(width: 816, height: 500)
    try await Task.sleep(for: .milliseconds(150))
    func scrolls(_ view: NSView) -> [NSScrollView] {
      (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
    }
    let scroll = try XCTUnwrap(scrolls(host).first)
    let before = scroll.documentView?.frame
    let windowsBefore = Set(NSApp.windows.map(\.windowNumber))
    store.notices.show(id: "restore-one", title: "已恢复任务", level: .info, taskID: "one")
    try await Task.sleep(for: .milliseconds(150))
    host.layoutSubtreeIfNeeded()
    XCTAssertEqual(scroll.documentView?.frame, before)
    XCTAssertEqual(Set(NSApp.windows.map(\.windowNumber)), windowsBefore)
    XCTAssertNil(window.attachedSheet)
    if let directory = ProcessInfo.processInfo.environment["SHIPIOS_SETTINGS_SNAPSHOTS"] {
      let root = URL(fileURLWithPath: directory)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        .write(to: root.appendingPathComponent("archive-restore-notice.png"))
    }
  }
}
