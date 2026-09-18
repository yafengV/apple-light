import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class SettingsTextEditorTests: XCTestCase {
  func testFocusRequestRunsOnceAndCannotStealFocusAfterDisableOrTeardown() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 100),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let editor = SettingsTextEditor.TextView(frame: .init(x: 0, y: 0, width: 400, height: 100))
    let scroll = NSScrollView(frame: editor.frame)
    scroll.documentView = editor
    window.contentView = scroll
    let coordinator = SettingsTextEditor(text: .constant("draft"), label: "Editor").makeCoordinator()
    let request = UUID()
    coordinator.updateFocus(editor, enabled: true, request: request)
    await Task.yield()
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertTrue(window.firstResponder === editor)
    window.makeFirstResponder(nil)
    coordinator.updateFocus(editor, enabled: true, request: request)
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertFalse(window.firstResponder === editor)
    coordinator.updateFocus(editor, enabled: true, request: UUID())
    coordinator.updateFocus(editor, enabled: false, request: nil)
    coordinator.updateFocus(editor, enabled: true, request: nil)
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertFalse(window.firstResponder === editor)
    editor.isHidden = true
    coordinator.updateFocus(editor, enabled: true, request: UUID())
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertFalse(window.firstResponder === editor)
    editor.isHidden = false
    coordinator.updateFocus(editor, enabled: true, request: UUID())
    SettingsTextEditor.dismantleNSView(scroll, coordinator: coordinator)
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertFalse(window.firstResponder === editor)
  }

  func testCompositionAndDismantledCallbacksDoNotPublishPartialDrafts() {
    var draft = "Saved draft"
    let view = SettingsTextEditor(text: Binding(get: { draft }, set: { draft = $0 }), label: "Draft")
    let coordinator = view.makeCoordinator()
    let editor = SettingsTextEditor.TextView()
    let scroll = NSScrollView()
    scroll.documentView = editor
    editor.setMarkedText("pin", selectedRange: .init(location: 3, length: 0),
      replacementRange: .init(location: NSNotFound, length: 0))
    coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
    XCTAssertEqual(draft, "Saved draft")
    editor.unmarkText()
    editor.string = "Committed composition"
    coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
    XCTAssertEqual(draft, "Committed composition")
    SettingsTextEditor.dismantleNSView(scroll, coordinator: coordinator)
    editor.string = "Late callback"
    coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
    XCTAssertEqual(draft, "Committed composition")
    XCTAssertFalse(editor.acceptsFirstResponder)
  }

  func testRetainedEditorLeavesKeyLoopWhenDisabledAndKeepsDraft() async throws {
    _ = NSApplication.shared
    var draft = "Uncommitted settings draft"
    func root(_ enabled: Bool) -> some View {
      SettingsTextEditor(text: Binding(get: { draft }, set: { draft = $0 }), label: "Test settings")
        .disabled(!enabled).frame(width: 400, height: 100)
    }
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 100),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: root(true))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? SettingsTextEditor.TextView }.first)
    XCTAssertTrue(editor.acceptsFirstResponder)
    window.makeFirstResponder(editor)
    editor.insertText("!", replacementRange: .init(location: editor.string.utf16.count, length: 0))
    XCTAssertEqual(draft, "Uncommitted settings draft!")
    host.rootView = root(false)
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(descendants(host).contains { $0 === editor })
    XCTAssertFalse(editor.acceptsFirstResponder)
    XCTAssertFalse(editor.canBecomeKeyView)
    XCTAssertFalse(editor.isEditable)
    XCTAssertFalse(editor.isSelectable)
    XCTAssertFalse(window.firstResponder === editor)
    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "x",
      charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
    editor.keyDown(with: event)
    XCTAssertEqual(editor.string, draft)
    host.rootView = root(true)
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(editor.acceptsFirstResponder)
    XCTAssertTrue(editor.isEditable)
    XCTAssertEqual(editor.string, "Uncommitted settings draft!")
  }

  func testTabAndBackTabMoveBetweenControlsWithoutInsertingText() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 160),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let before = NSTextField(frame: .init(x: 0, y: 120, width: 200, height: 20))
    let editor = SettingsTextEditor.TextView(frame: .init(x: 0, y: 40, width: 200, height: 70))
    let after = NSTextField(frame: .init(x: 0, y: 10, width: 200, height: 20))
    for view in [before, editor, after] { window.contentView?.addSubview(view) }
    before.nextKeyView = editor
    editor.nextKeyView = after
    after.nextKeyView = before
    editor.string = "Draft"
    let cases: [(NSEvent.ModifierFlags, NSTextField)] = [([], after), (.shift, before)]
    for (flags, destination) in cases {
      window.makeFirstResponder(editor)
      let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
        timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\t",
        charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
      editor.keyDown(with: event)
      XCTAssertTrue(destination.currentEditor() === window.firstResponder)
      XCTAssertEqual(editor.string, "Draft")
    }
  }
}
