import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class TaskWindowImmediateNavigationTests: XCTestCase {
  private final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
  }

  func testNumericReturnMountsTaskComposerBeforeNextNativeKey() async throws {
    try await Self.verifyNumericReturn(actualKeyWindow: false)
  }

  static func verifyNumericReturn(actualKeyWindow: Bool) async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.libraryLoaded = true; store.scopeLoaded = true; store.connected = true
    store.library.tasks = [.init(id: "task", project: "", title: "Task", runIDs: [])]
    let resources = TaskWindowResources()
    resources.prepare("task", store: store)
    defer { resources.shutdown(); store.workspace.browser.shutdown() }
    let tabs = try XCTUnwrap(resources.tasks["task"])
    tabs.newBrowser()
    let browser = try XCTUnwrap(tabs.browser.session.selected)
    browser.setCustomTitle("Keep this page")
    browser.setAddressDraft("http://127.0.0.1:9/unsent")
    let windowType: NSWindow.Type = actualKeyWindow ? NSWindow.self : KeyWindow.self
    let window = windowType.init(contentRect: .init(x: 0, y: 0, width: 760, height: 720),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: TaskWindowView(store: store, taskID: "task",
      tabs: tabs, resources: resources, renameHistory: TaskRenameHistory(),
      onNavigate: { _ in }, canGoBack: false, canGoForward: false, onMove: { _ in }))
    window.contentView = host
    defer { window.contentView = nil; window.close() }
    if actualKeyWindow {
      window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
      try await Task.sleep(for: .milliseconds(250))
      XCTAssertTrue(window.isKeyWindow)
    }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    func editor(_ view: NSView) -> ComposerNativeTextView? {
      if let found = view as? ComposerNativeTextView { return found }
      return view.subviews.lazy.compactMap { editor($0) }.first
    }
    XCTAssertNil(editor(host))
    XCTAssertTrue(window.makeFirstResponder(try XCTUnwrap(tabs.browser.session.addressField)))
    let shortcut = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
      modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber,
      context: nil, characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18))
    NSApp.sendEvent(shortcut)
    // Do not yield or lay out here: this is the next queued native key.
    XCTAssertNil(tabs.focusedID)
    let current = try XCTUnwrap(editor(host), "Numeric navigation must finish mounting its chat")
    XCTAssertTrue(window.firstResponder === current)
    for character in "t08-task-input" {
      window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
        context: nil, characters: String(character), charactersIgnoringModifiers: String(character),
        isARepeat: false, keyCode: 0)))
    }
    XCTAssertEqual(store.taskWindowDraft("task"), "t08-task-input")
    XCTAssertEqual(current.string, "t08-task-input")
    XCTAssertEqual(current.selectedRange().location, "t08-task-input".utf16.count)
  }
}
