import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class ComposerModelPopoverTests: XCTestCase {
  func testNativeModelPopoverDismissalReturnsTheFirstQueuedKeyToComposer() async throws {
    guard ProcessInfo.processInfo.environment["SHIPIOS_TEST_FOREGROUND_ALLOWED"] == "1" else {
      throw XCTSkip("Requires the interactive AppKit host and an actual key window")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    defer { try? FileManager.default.removeItem(at: root) }
    var config = ModelConfiguration()
    config.baseURL = "http://127.0.0.1:9/v1"
    config.model = "offline-model"
    try store.saveModelConfiguration(config)
    store.draft = "保留草稿"
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 680, height: 340),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: ComposerView(store: store))
    window.contentView = host
    defer { window.contentView = nil; window.close() }
    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    try await Task.sleep(for: .milliseconds(200))
    host.layoutSubtreeIfNeeded()
    func find<T: NSView>(_ view: NSView, _: T.Type) -> [T] {
      (view as? T).map { [$0] } ?? view.subviews.flatMap { find($0, T.self) }
    }
    let editor = try XCTUnwrap(find(host, ComposerNativeTextView.self).first)
    XCTAssertTrue(window.makeFirstResponder(editor))
    editor.setSelectedRange(.init(location: editor.string.utf16.count, length: 0))
    for character in ["a", "b"] {
      store.openModelPicker()
      var owner: ComposerModelPopover.Coordinator?
      for _ in 0..<60 {
        host.layoutSubtreeIfNeeded()
        owner = find(host, ComposerModelPopover.Anchor.self).first?.owner
        if owner?.popover?.isShown == true { break }
        try await Task.sleep(for: .milliseconds(20))
      }
      let picker = try XCTUnwrap(owner)
      XCTAssertTrue(picker.popover?.isShown == true)
      if character == "a" {
        let popupWindow = try XCTUnwrap(picker.popover?.contentViewController?.view.window)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
          modifierFlags: [], timestamp: 0, windowNumber: popupWindow.windowNumber,
          context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
          isARepeat: false, keyCode: 53))
        XCTAssertTrue(picker.handleCancel(escape))
      } else { picker.close(restore: true) }
      // No queue hop between dismissal and this next native event.
      XCTAssertTrue(window.isKeyWindow)
      XCTAssertTrue(window.firstResponder === editor)
      let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
        context: nil, characters: character, charactersIgnoringModifiers: character,
        isARepeat: false, keyCode: character == "a" ? 0 : 11))
      window.sendEvent(key)
      XCTAssertEqual(store.draft, character == "a" ? "保留草稿a" : "保留草稿ab")
      XCTAssertFalse(store.showingModelPicker)
      XCTAssertEqual(store.modelConfiguration.model, "offline-model")
      try await Task.sleep(for: .milliseconds(50))
      XCTAssertTrue(window.firstResponder === editor, "No late menu focus may reclaim the editor")
    }
    await store.shutdown()
  }
}
